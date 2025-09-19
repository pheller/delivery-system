defmodule Prodigy.Server.Service.BulletinBoards do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Bulletin Board Requests
  """

  import Ecto.Query

  require Logger

  alias Prodigy.Core.Data.{Club, Post, Repo, Topic, User, UserClub}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  def handle(%Fm0{payload: <<0x3, payload::binary>>} = request, %Context{} = context) do
    {context, response} = case payload do
      # Enter club
      <<0, 0, 0x65, club_handle::bytes-size(3)>> ->
        handle_enter_club(club_handle, context)

      # List topics for club
      <<0, 0, 0xF, club_handle::bytes-size(3), 0xC>> ->
        handle_list_topics(club_handle, context)

      # Start cursor for notes since date/time
      <<0, 0, 0x67, 0x24, mon::bytes-size(2), day::bytes-size(2), min::bytes-size(2),
        hour::bytes-size(2), topic_id::16-big>> ->
        handle_start_note_cursor(mon, day, min, hour, topic_id, context)

      # Navigate note headers
      <<0, 0, 0x67, direction, _mon::bytes-size(2), _day::bytes-size(2),
        topic_len::16-big, _topic_text::binary-size(topic_len)>> ->
        handle_navigate_note_cursor(direction, context)

      # Get note header and first page
      <<0, 0, 0x68, 0, note_id::16-big>> ->
        handle_get_note_first(note_id, context)

      # Get rest of post body
      <<0, 0, 0x68, 0x40, note_id::16-big>> ->
        handle_get_note_rest(note_id, context)

      # Get replies for current post
      <<0, 0, 0x68, 0x28, 0::16-big, mmdd::binary-size(4), hhmm::binary-size(4)>> ->
        handle_start_reply_traversal(mmdd, hhmm, context)

      # Get rest of reply body
      <<0, 0, 0x68, 0x61>> ->
        handle_get_reply_rest(context)

      # Get next reply
      <<0, 0, 0x68, 0x21>> ->
        handle_get_next_reply(context)

      _ ->
        handle_unknown_request(payload, context)
    end

    case response do
      {:ok, payload} -> {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, context}
    end
  end

  # ============================================================================
  # Request Handlers
  # ============================================================================

  defp handle_enter_club(club_handle, context) do
    club = Repo.get_by(Club, handle: club_handle)

    response = case club do
      nil ->
        Logger.warn("Club with handle #{club_handle} not found")
        <<0, 0xFF::16, 0::32, 0::16-big>>

      %Club{id: club_id, name: name} ->
        # Get or create the user's last read date for this club
        last_read_mmdd = get_last_read_mmdd(context.user.id, club_id)

        # Store club_id in context for later use
        context = Map.put(context, :current_club_id, club_id)

        <<
          0,
          0::16,
          last_read_mmdd::binary-size(4),
          byte_size(name)::16-big,
          name::binary
        >>
    end

    {context, {:ok, response}}
  end

  defp handle_list_topics(club_handle, context) do
    club = Club
           |> where([c], c.handle == ^club_handle)
           |> preload(topics: ^from(t in Topic, order_by: [asc: t.id]))
           |> Repo.one()

    topics = if club, do: club.topics, else: []

    if is_nil(club), do: Logger.warn("Club with handle #{club_handle} not found")

    topics_binary = build_topics_binary(topics)

    response = <<
      0x1,                          # Response type
      0::16-big,                    # Unknown value
      length(topics)::16-big,       # Number of topics
      0::16-big,                    # Unknown value
      topics_binary::binary         # All topic data
    >>

    {context, {:ok, response}}
  end

  defp handle_start_note_cursor(mon, day, min, hour, topic_id, context) do
    Logger.debug("Starting note cursor for topic #{topic_id} from #{mon}/#{day} #{hour}:#{min}")

    threshold_datetime = parse_datetime(mon, day, min, hour)
    note_ids = get_posts_since_threshold(topic_id, threshold_datetime)

    topic = Repo.get(Topic, topic_id)
    update_last_read_date(context.user.id, topic.club_id)

    context = Map.merge(context, %{
      bb: %{
        note_ids: note_ids,
        offset: 0,
        topic_id: topic_id,
        current_post_id: nil,
        reply_ids: [],
        reply_offset: 0,
        rest: nil
      }
    })

    {context, {:ok, get_index_page(context.bb)}}
  end

  defp handle_navigate_note_cursor(direction, context) do
    Logger.debug("note pagination, direction: #{direction}")

    new_offset = calculate_new_offset(direction, context.bb.offset, length(context.bb.note_ids))
    new_context = %{context | bb: %{context.bb | offset: new_offset}}

    {new_context, {:ok, get_index_page(new_context.bb)}}
  end

  defp handle_get_note_first(note_id, context) do
    Logger.debug("Getting note #{note_id} header and first page")

    actual_post_id = Enum.at(context.bb.note_ids, note_id - 1)
    {response, rest} = get_post_by_id(actual_post_id)

    new_context = %{context | bb: %{context.bb |
      rest: rest,
      current_post_id: actual_post_id
    }}

    {new_context, {:ok, response}}
  end

  defp handle_get_note_rest(_note_id, context) do
    Logger.debug("Getting rest of note body")

    response = <<
      0x0,
      0x0,
      byte_size(context.bb.rest)::16-big,
      context.bb.rest::binary
    >>

    new_context = %{context | bb: %{context.bb | rest: nil}}
    {new_context, {:ok, response}}
  end

  defp handle_start_reply_traversal(mmdd, hhmm, context) do
    threshold_datetime = parse_datetime_from_mmdd_hhmm(mmdd, hhmm)
    replies_with_dates = get_all_replies_with_dates(context.bb.current_post_id)
    reply_ids = Enum.map(replies_with_dates, & &1.id)
    starting_offset = find_reply_starting_offset(replies_with_dates, threshold_datetime)
    available_replies = length(reply_ids) - starting_offset

    if available_replies > 0 do
      first_reply_id = Enum.at(reply_ids, starting_offset)

      {response, rest} = get_post_by_id(first_reply_id, starting_offset + 1)

      new_context = %{context | bb: %{context.bb |
        reply_ids: reply_ids,
        reply_offset: starting_offset,
        rest: rest
      }}

      {new_context, {:ok, response}}
    else
      {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
    end
  end

  defp handle_get_reply_rest(context) do
    Logger.debug("Getting rest of reply body")

    response = <<
      0x0,
      0x0,
      byte_size(context.bb.rest || <<>>)::16-big,
      (context.bb.rest || <<>>)::binary
    >>

    new_context = %{context | bb: %{context.bb | rest: nil}}
    {new_context, {:ok, response}}
  end

  defp handle_get_next_reply(context) do
    Logger.debug("Getting next reply")

    new_offset = context.bb.reply_offset + 1

    if new_offset < length(context.bb.reply_ids) do
      next_reply_id = Enum.at(context.bb.reply_ids, new_offset)
      {response, rest} = get_post_by_id(next_reply_id, new_offset + 1)

      new_context = %{context | bb: %{context.bb |
        reply_offset: new_offset,
        rest: rest
      }}

      {new_context, {:ok, response}}
    else
      {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
    end
  end

  defp handle_unknown_request(request, context) do
    Logger.warning("unhandled bulletin board request: #{inspect(request, base: :hex, limit: :infinity)}")
    {context, {:ok, <<0>>}}
  end

  # ============================================================================
  # Helper Functions - Date/Time Parsing
  # ============================================================================

  defp parse_datetime(mon, day, min, hour) do
    current_year = Date.utc_today().year
    month = String.to_integer(mon)
    day_int = String.to_integer(day)
    minute = String.to_integer(min)
    hour_int = String.to_integer(hour)

    {:ok, naive_datetime} = NaiveDateTime.new(current_year, month, day_int, hour_int, minute, 0)
    DateTime.from_naive!(naive_datetime, "Etc/UTC")
  end

  defp parse_datetime_from_mmdd_hhmm(mmdd, hhmm) do
    month = String.to_integer(binary_part(mmdd, 0, 2))
    day = String.to_integer(binary_part(mmdd, 2, 2))
    hour = String.to_integer(binary_part(hhmm, 0, 2))
    minute = String.to_integer(binary_part(hhmm, 2, 2))

    current_year = Date.utc_today().year
    {:ok, threshold_datetime} = NaiveDateTime.new(current_year, month, day, hour, minute, 0)

    threshold_datetime
  end

  # ============================================================================
  # Helper Functions - Data Building
  # ============================================================================

  defp build_topics_binary(topics) do
    topics
    |> Enum.map(fn topic ->
      <<
        byte_size(topic.title)::16-big,
        topic.title::binary,
        1,                              # Unknown byte (placeholder)
        2::32-big,                      # Unknown 32-bit value (placeholder)
        topic.id::16-big
      >>
    end)
    |> IO.iodata_to_binary()
  end

  defp calculate_new_offset(direction, current_offset, total_posts) do
    case direction do
      0x01 -> max(0, current_offset - 3)                           # Previous page
      0x02 -> min(current_offset + 3, total_posts - 3)            # Next page
      # 0x04 -> ?
      0x10 -> 0                                                     # Reset to beginning
      _ -> current_offset
    end
  end

  defp find_reply_starting_offset(replies_with_dates, threshold_datetime) do

    result = replies_with_dates
             |> Enum.find_index(fn %{sent_date: date} ->
      comparison = NaiveDateTime.compare(date, threshold_datetime)
      is_after_or_equal = comparison in [:gt, :eq]
    end)

    offset = result || 0
  end

  # ============================================================================
  # Database Queries
  # ============================================================================

  defp get_posts_since_threshold(topic_id, threshold_datetime) do
    Repo.all(
      from p in Post,
      left_join: r in Post, on: r.in_reply_to == p.id,
      where: p.topic_id == ^topic_id and is_nil(p.in_reply_to),
      where: p.sent_date >= ^threshold_datetime or r.sent_date >= ^threshold_datetime,
      group_by: p.id,
      order_by: [asc: p.sent_date],
      select: p.id
    )
  end

  # ============================================================================
  # Reply Tree Queries
  # ============================================================================

  # Consolidated function for all reply tree queries
  defp get_reply_tree(post_id, opts \\ []) do
    # Build the recursive CTE base
    base_query = build_reply_tree_base(post_id)

    # Apply options
    base_query
    |> apply_threshold_filter(Keyword.get(opts, :threshold))
    |> apply_reply_select(Keyword.get(opts, :select, :ids))
    |> Repo.all()
    |> format_reply_result(Keyword.get(opts, :select, :ids))
  end

  defp build_reply_tree_base(post_id) do
    # Initial query: direct replies to the given post
    initial_query =
      Post
      |> where([p], p.in_reply_to == ^post_id)
      |> select([p], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    # Recursive query: replies to replies
    recursion_query =
      Post
      |> join(:inner, [p], rt in "reply_tree", on: p.in_reply_to == rt.id)
      |> select([p, rt], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    # Combine them
    reply_tree_query =
      initial_query
      |> union_all(^recursion_query)

    Post
    |> recursive_ctes(true)
    |> with_cte("reply_tree", as: ^reply_tree_query)
    |> join(:inner, [p], rt in "reply_tree", on: p.id == rt.id)
    |> order_by([p, rt], asc: rt.sent_date)
  end

  defp apply_threshold_filter(query, nil), do: query
  defp apply_threshold_filter(query, threshold_datetime) do
    where(query, [p, rt], rt.sent_date >= ^threshold_datetime)
  end

  defp apply_reply_select(query, :ids) do
    select(query, [p, rt], rt.id)
  end
  defp apply_reply_select(query, :with_dates) do
    select(query, [p, rt], %{id: rt.id, sent_date: rt.sent_date})
  end

  defp format_reply_result(result, :ids), do: result
  defp format_reply_result(result, :with_dates) do
    result  # Already in the right format
  end

  # Wrapper functions for backward compatibility and clarity
  defp get_all_replies(post_id, threshold_datetime) do
    get_reply_tree(post_id, threshold: threshold_datetime, select: :ids)
  end

  defp get_all_replies_with_dates(post_id) do
    get_reply_tree(post_id, select: :with_dates)
  end

  defp get_all_replies_with_max_date(post_id) do
    replies = get_reply_tree(post_id, select: :with_dates)

    case replies do
      [] ->
        {[], nil}
      _ ->
        ids = Enum.map(replies, & &1.id)
        max_date = replies
                   |> Enum.map(& &1.sent_date)
                   |> Enum.max()
        {ids, max_date}
    end
  end

  def get_post_by_id(id, result_number \\ nil) do
    {_reply_ids, newest_reply_date} = get_all_replies_with_max_date(id)

    post = Repo.one(
      from p in Post,
      where: p.id == ^id,
      left_join: r in Post, on: r.in_reply_to == p.id,
      left_join: u in User, on: u.id == p.from_id,
      preload: [:topic],
      group_by: [p.id, u.first_name, u.last_name],
      select: %Post{p |
        reply_count: count(r.id),
        last_reply_date: max(r.sent_date),
        from_name: fragment("COALESCE(? || ' ' || ?, ?, ?)",
          u.first_name, u.last_name, u.first_name, p.from_id)
      }
    )

    sent_mmdd = Calendar.strftime(post.sent_date, "%m%d")
    sent_hhmm_24hr = Calendar.strftime(post.sent_date, "%H%M")
    last_mmdd = if post.last_reply_date do
      Calendar.strftime(post.last_reply_date, "%m%d")
    else
      "    "
    end

    newest_mmddHHMM = if newest_reply_date do
      Calendar.strftime(newest_reply_date, "%m%d%H%M")
    else
      "        "
    end

    to_name = if is_nil(post.to_name) or post.to_name == "", do: "ALL", else: post.to_name

    {first, rest} = case post.body do
      <<first::binary-size(280), rest::binary>> -> {first, rest}
      body -> {body, <<>>}
    end

    response = <<
      0x0,
      0x0,
      post.from_id::binary,
      sent_mmdd::binary,
      sent_hhmm_24hr::binary-size(4),
      newest_mmddHHMM::binary-size(8),
      (result_number || 0)::16-big,
      (post.reply_count || 0)::16-big,
      0,
      0::16-big,
      byte_size(post.topic.title)::16-big,
      post.topic.title::binary,
      byte_size(to_name)::16-big,
      to_name::binary,
      byte_size(post.from_name)::16-big,
      post.from_name::binary,
      byte_size(post.subject)::16-big,
      post.subject::binary,
      byte_size(post.body)::16-big,
      byte_size(first)::16-big,
      first::binary
    >>

    {response, rest}
  end

  defp get_index_page(%{note_ids: note_ids, offset: offset}, page_size \\ 3) do
    page_note_ids = Enum.slice(note_ids, offset, page_size)
    total_notes = length(note_ids)
    notes_this_page = length(page_note_ids)

    notes_data = if notes_this_page > 0 do
      notes_with_stats = Repo.all(
        from p in Post,
        where: p.id in ^page_note_ids,
        left_join: r in Post, on: r.in_reply_to == p.id,
        left_join: u in User, on: u.id == p.from_id,
        group_by: [p.id, p.sent_date, p.to_name, p.from_id, p.subject, u.first_name, u.last_name],
        order_by: [asc: p.sent_date],
        select: %{
          sent_date: p.sent_date,
          to_name: p.to_name,
          subject: p.subject,
          reply_count: count(r.id),
          last_reply_date: max(r.sent_date),
          from_name: fragment("COALESCE(? || ' ' || ?, ? || '', ?)",
            u.first_name, u.last_name, u.first_name, p.from_id)
        }
      )

      notes_with_stats
      |> Enum.map(fn post ->
        sent_mmdd = Calendar.strftime(post.sent_date, "%m%d")
        last_reply_mmdd = if post.last_reply_date do
          Calendar.strftime(post.last_reply_date, "%m%d")
        else
          "    "
        end

        to_name = if is_nil(post.to_name) or post.to_name == "", do: "ALL", else: post.to_name

        <<
          sent_mmdd::binary-size(4),
          last_reply_mmdd::binary-size(4),
          (post.reply_count || 0)::16-big,
          byte_size(to_name)::16-big, to_name::binary,
          byte_size(post.from_name)::16-big, post.from_name::binary,
          byte_size(post.subject)::16-big, post.subject::binary
        >>
      end)
      |> IO.iodata_to_binary()
    else
      <<>>
    end

    <<
      0x1,
      0x0,
      0x0::32-big,
      total_notes::16-big,
      notes_this_page::16-big,
      notes_data::binary
    >>
  end

  defp get_last_read_mmdd(user_id, club_id) do
    case Repo.get_by(UserClub, user_id: user_id, club_id: club_id) do
      nil ->
        # Never read this club before, return today's date
        # This ensures they only see new posts going forward
        today = Date.utc_today()
        Calendar.strftime(today, "%m%d")

      %UserClub{last_read_date: last_read} ->
        Calendar.strftime(last_read, "%m%d")
    end
  end

  defp update_last_read_date(user_id, club_id) do
    now = DateTime.utc_now()

    case Repo.get_by(UserClub, user_id: user_id, club_id: club_id) do
      nil ->
        # First time reading this club, create the record
        %UserClub{}
        |> UserClub.changeset(%{
          user_id: user_id,
          club_id: club_id,
          last_read_date: now
        })
        |> Repo.insert()

      existing ->
        # Update existing record
        existing
        |> UserClub.changeset(%{last_read_date: now})
        |> Repo.update()
    end
    |> case do
         {:ok, _} ->
           Logger.debug("Updated last read date for user #{user_id} in club #{club_id}")
         {:error, changeset} ->
           Logger.error("Failed to update last read date: #{inspect(changeset.errors)}")
       end
  end
end