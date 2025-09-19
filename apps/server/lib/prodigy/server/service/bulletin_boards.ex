defmodule Prodigy.Server.Service.BulletinBoards do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Bulletin Board Requests
  """

  import Ecto.Query

  require Logger

  alias Prodigy.Core.Data.{Club, Post, Repo, Topic, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  # ============================================================================
  # Public API
  # ============================================================================

  def handle(%Fm0{payload: <<0x3, payload::binary>>} = request, %Context{} = context) do
    Logger.info("bbs got payload #{inspect(payload, base: :hex, limit: :infinity)}")

    {context, response} = route_request(payload, context)

    case response do
      {:ok, payload} -> {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, context}
    end
  end

  # ============================================================================
  # Request Routing
  # ============================================================================

  defp route_request(payload, context) do
    case payload do
      # Enter bulletin board
      <<0, 0, 0x65, bbs_handle::bytes-size(3)>> ->
        handle_enter_board(bbs_handle, context)

      # List topics for bulletin board
      <<0, 0, 0xF, bbs_handle::bytes-size(3), 0xC>> ->
        handle_list_topics(bbs_handle, context)

      # Start cursor for posts since date/time
      <<0, 0, 0x67, 0x24, mon::bytes-size(2), day::bytes-size(2), min::bytes-size(2),
        hour::bytes-size(2), topic_id::16-big>> ->
        handle_start_post_cursor(mon, day, min, hour, topic_id, context)

      # Navigate post headers
      <<0, 0, 0x67, direction, _mon::bytes-size(2), _day::bytes-size(2),
        topic_len::16-big, _topic_text::binary-size(topic_len)>> ->
        handle_navigate_posts(direction, context)

      # Get post header and first page
      <<0, 0, 0x68, 0, post_id::16-big>> ->
        handle_get_post_first_page(post_id, context)

      # Get rest of post body
      <<0, 0, 0x68, 0x40, post_id::16-big>> ->
        handle_get_post_rest(post_id, context)

      # Get replies for current post
      <<0, 0, 0x68, 0x28, 0::16-big, mmdd::binary-size(4), hhmm::binary-size(4)>> ->
        handle_get_replies(mmdd, hhmm, context)

      # Get rest of reply body
      <<0, 0, 0x68, 0x61>> ->
        handle_get_reply_rest(context)

      # Get next reply
      <<0, 0, 0x68, 0x21>> ->
        handle_get_next_reply(context)

      _ ->
        handle_unknown_request(payload, context)
    end
  end

  # ============================================================================
  # Request Handlers
  # ============================================================================

  defp handle_enter_board(bbs_handle, context) do
    club = Repo.get_by(Club, handle: bbs_handle)

    response = case club do
      nil ->
        Logger.error("Club with handle #{bbs_handle} not found")
        <<0, 0xFF::16, 0::32, 0::16-big>>

      %Club{name: name} ->
        <<
          0,
          0::16,
          "0914"::binary,  # TODO: Store user's last read MMDD per club
          byte_size(name)::16-big,
          name::binary
        >>
    end

    {context, {:ok, response}}
  end

  defp handle_list_topics(bbs_handle, context) do
    club = Club
           |> where([c], c.handle == ^bbs_handle)
           |> preload(topics: ^from(t in Topic, order_by: [asc: t.id]))
           |> Repo.one()

    topics = if club, do: club.topics, else: []

    if is_nil(club), do: Logger.warn("Club with handle #{bbs_handle} not found")

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

  defp handle_start_post_cursor(mon, day, min, hour, topic_id, context) do
    Logger.info("start cursor for bbs topic #{topic_id}")

    threshold_datetime = parse_datetime(mon, day, min, hour)
    post_ids = get_posts_since_threshold(topic_id, threshold_datetime)

    context = Map.merge(context, %{
      bb: %{
        post_ids: post_ids,
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

  defp handle_navigate_posts(direction, context) do
    Logger.info("bbs topic pagination request, direction: #{direction}")

    new_offset = calculate_new_offset(direction, context.bb.offset, length(context.bb.post_ids))
    new_context = %{context | bb: %{context.bb | offset: new_offset}}

    {new_context, {:ok, get_index_page(new_context.bb)}}
  end

  defp handle_get_post_first_page(post_id, context) do
    Logger.info("bbs request for post #{post_id} (header and 1st page)")

    actual_post_id = Enum.at(context.bb.post_ids, post_id - 1)
    {response, rest} = get_post_by_id(actual_post_id)

    new_context = %{context | bb: %{context.bb |
      rest: rest,
      current_post_id: actual_post_id
    }}

    {new_context, {:ok, response}}
  end

  defp handle_get_post_rest(_post_id, context) do
    Logger.info("bbs request for post rest")

    response = <<
      0x0,
      0x0,
      byte_size(context.bb.rest)::16-big,
      context.bb.rest::binary
    >>

    new_context = %{context | bb: %{context.bb | rest: nil}}
    {new_context, {:ok, response}}
  end

  defp handle_get_replies(mmdd, hhmm, context) do
    Logger.info("populate reply list, get first reply header and first body page")
    Logger.info("Raw input - mmdd: #{inspect(mmdd, base: :hex)}, hhmm: #{inspect(hhmm, base: :hex)}")

    threshold_datetime = parse_datetime_from_mmdd_hhmm(mmdd, hhmm)
    Logger.info("Parsed threshold datetime: #{inspect(threshold_datetime)}")

    replies_with_dates = get_all_replies_with_dates(context.bb.current_post_id)
    Logger.info("Found #{length(replies_with_dates)} total replies for post #{context.bb.current_post_id}")

    # Log first few reply dates for comparison
    replies_with_dates
    |> Enum.take(5)
    |> Enum.each(fn %{id: id, sent_date: date} ->
      Logger.info("Reply #{id} sent_date: #{inspect(date)}")
    end)

    reply_ids = Enum.map(replies_with_dates, & &1.id)

    starting_offset = find_reply_starting_offset(replies_with_dates, threshold_datetime)
    Logger.info("Starting offset: #{starting_offset}")

    available_replies = length(reply_ids) - starting_offset
    Logger.info("Available replies after threshold: #{available_replies}")

    # Log the comparison results for debugging
    if length(replies_with_dates) > 0 do
      replies_with_dates
      |> Enum.with_index()
      |> Enum.take(3)
      |> Enum.each(fn {%{sent_date: date}, idx} ->
        comparison = NaiveDateTime.compare(date, threshold_datetime)
        Logger.info("Reply #{idx}: #{inspect(date)} vs threshold #{inspect(threshold_datetime)} = #{comparison}")
      end)
    end

    if available_replies > 0 do
      first_reply_id = Enum.at(reply_ids, starting_offset)
      Logger.info("Returning first reply id: #{first_reply_id} at offset #{starting_offset}")

      {response, rest} = get_post_by_id(first_reply_id, starting_offset + 1)

      new_context = %{context | bb: %{context.bb |
        reply_ids: reply_ids,
        reply_offset: starting_offset,
        rest: rest
      }}

      {new_context, {:ok, response}}
    else
      Logger.info("No replies found after threshold")
      {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
    end
  end

  defp handle_get_reply_rest(context) do
    Logger.info("get rest of reply body")

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
    Logger.info("get next reply header and first body page")

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

    Logger.info("Parsing datetime - Month: #{month}, Day: #{day}, Hour: #{hour}, Minute: #{minute}")

    current_year = Date.utc_today().year
    {:ok, threshold_datetime} = NaiveDateTime.new(current_year, month, day, hour, minute, 0)

    Logger.info("Created NaiveDateTime: #{inspect(threshold_datetime)}")

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
      0x10 -> 0                                                     # Reset to beginning
      _ -> current_offset
    end
  end

  defp find_reply_starting_offset(replies_with_dates, threshold_datetime) do
    Logger.info("Finding starting offset for threshold: #{inspect(threshold_datetime)}")

    result = replies_with_dates
             |> Enum.find_index(fn %{sent_date: date} ->
      comparison = NaiveDateTime.compare(date, threshold_datetime)
      is_after_or_equal = comparison in [:gt, :eq]
      Logger.info("  Comparing #{inspect(date)}: #{comparison}, passes: #{is_after_or_equal}")
      is_after_or_equal
    end)

    offset = result || 0
    Logger.info("find_reply_starting_offset calculated: #{inspect(result)}, returning: #{offset}")
    offset
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
  # Existing Helper Functions (unchanged)
  # ============================================================================

  defp get_all_replies(post_id, threshold_datetime) do
    initial_query =
      Post
      |> where([p], p.in_reply_to == ^post_id)
      |> select([p], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    recursion_query =
      Post
      |> join(:inner, [p], rt in "reply_tree", on: p.in_reply_to == rt.id)
      |> select([p, rt], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    reply_tree_query =
      initial_query
      |> union_all(^recursion_query)

    Post
    |> recursive_ctes(true)
    |> with_cte("reply_tree", as: ^reply_tree_query)
    |> join(:inner, [p], rt in "reply_tree", on: p.id == rt.id)
    |> where([p, rt], rt.sent_date >= ^threshold_datetime)
    |> order_by([p, rt], asc: rt.sent_date)
    |> select([p, rt], rt.id)
    |> Repo.all()
  end

  defp get_all_replies_with_dates(post_id) do
    initial_query =
      Post
      |> where([p], p.in_reply_to == ^post_id)
      |> select([p], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    recursion_query =
      Post
      |> join(:inner, [p], rt in "reply_tree", on: p.in_reply_to == rt.id)
      |> select([p, rt], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    reply_tree_query =
      initial_query
      |> union_all(^recursion_query)

    Post
    |> recursive_ctes(true)
    |> with_cte("reply_tree", as: ^reply_tree_query)
    |> join(:inner, [p], rt in "reply_tree", on: p.id == rt.id)
    |> order_by([p, rt], asc: rt.sent_date)
    |> select([p, rt], %{id: rt.id, sent_date: rt.sent_date})
    |> Repo.all()
  end

  defp get_all_replies_with_max_date(post_id) do
    initial_query =
      Post
      |> where([p], p.in_reply_to == ^post_id)
      |> select([p], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    recursion_query =
      Post
      |> join(:inner, [p], rt in "reply_tree", on: p.in_reply_to == rt.id)
      |> select([p, rt], %{id: p.id, sent_date: p.sent_date, in_reply_to: p.in_reply_to})

    reply_tree_query =
      initial_query
      |> union_all(^recursion_query)

    result = Post
             |> recursive_ctes(true)
             |> with_cte("reply_tree", as: ^reply_tree_query)
             |> join(:inner, [p], rt in "reply_tree", on: p.id == rt.id)
             |> select([p, rt], %{id: rt.id, sent_date: rt.sent_date})
             |> Repo.all()

    case result do
      [] ->
        {[], nil}
      replies ->
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

  defp get_index_page(%{post_ids: post_ids, offset: offset}, page_size \\ 3) do
    page_post_ids = Enum.slice(post_ids, offset, page_size)
    total_posts = length(post_ids)
    posts_this_page = length(page_post_ids)

    posts_data = if posts_this_page > 0 do
      posts_with_stats = Repo.all(
        from p in Post,
        where: p.id in ^page_post_ids,
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

      posts_with_stats
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

    res = <<
      0x1,
      0x0,
      0x0::32-big,
      total_posts::16-big,
      posts_this_page::16-big,
      posts_data::binary
    >>

    Logger.warning(inspect(res, base: :hex, limit: :infinity))
    res
  end
end