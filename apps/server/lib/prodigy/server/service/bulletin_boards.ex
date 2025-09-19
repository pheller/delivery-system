# Copyright 2022, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

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


  # Add this function near the top of the module:
  defp get_all_replies(post_id, threshold_datetime) do
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

    # Execute the recursive CTE
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

    # Execute the recursive CTE and get both IDs and max date
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
                   |> Enum.max()  # Just use Enum.max without DateTime
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

    # Format dates
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
      0x0,                              # 0x02 goes to safepage
      0x0,                              # skips some reply related stuff? dunno
      post.from_id::binary,             # fixed 7 bytes
      sent_mmdd::binary,                # sent date
      sent_hhmm_24hr::binary-size(4),   # sent time
      newest_mmddHHMM::binary-size(8),
      (result_number || 0)::16-big,
      (post.reply_count || 0)::16-big,
      0,                                # dunno
      0::16-big,                        # dunno
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

    # Fetch envelope data with a more efficient query
    posts_data = if posts_this_page > 0 do
      # Single query to get posts with reply stats
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

      # Build envelope binaries
      posts_with_stats
      |> Enum.map(fn post ->
        # Format dates
        sent_mmdd = Calendar.strftime(post.sent_date, "%m%d")
        last_reply_mmdd = if post.last_reply_date do
          Calendar.strftime(post.last_reply_date, "%m%d")
        else
          "    "
        end

        # Format to_name
        to_name = if is_nil(post.to_name) or post.to_name == "", do: "ALL", else: post.to_name

        # Build binary
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

  def handle(%Fm0{payload: <<0x3, payload::binary>>} = request, %Context{} = context) do

    Logger.info("bbs got payload #{inspect(payload, base: :hex, limit: :infinity)}")
    {context, response} =
      case payload do

        # user has entered a bulletin board, we need to get the last date they read it to populate the UI
        << 0, 0, 0x65, bbs_handle::bytes-size(3) >> ->
          club = Repo.get_by(Club, handle: bbs_handle)
          response = case club do
            nil ->
              Logger.error("Club with handle #{bbs_handle} not found")
              << 0, 0xFF::16, 0::32, 0::16-big >>
            %Club{name: name} ->
              <<
                0,
                0::16,
                "0914"::binary,           # TODO need a schema to store user's last read MMDD per club; what do we default to?
                byte_size(name)::16-big,
                name::binary
              >>
          end
          {context, {:ok, response}}

        # user requested a list of topics for a specified bulletin board
        <<0, 0, 0xF, bbs_handle::bytes-size(3), 0xC>> ->
          club = Club
                 |> where([c], c.handle == ^bbs_handle)
                 |> preload(topics: ^from(t in Topic, order_by: [asc: t.id]))
                 |> Repo.one()

          topics = if club, do: club.topics, else: []

          if is_nil(club), do: Logger.warn("Club with handle #{bbs_handle} not found")

          topic_count = length(topics)

          topics_binary = topics
          |> Enum.map(fn topic ->
              <<
                byte_size(topic.title)::16-big, # Length of title
                topic.title::binary,            # Topic title
                1,                              # Unknown byte (placeholder)
                2::32-big,                      # Unknown 32-bit value (placeholder)
                topic.id::16-big                # Topic ID
              >>
            end)
          |> IO.iodata_to_binary()

          response =
              <<
                0x1,                          # Response type?
                0::16-big,                    # Unknown value
                topic_count::16-big,          # Number of topics
                0::16-big,                    # Unknown value
                topics_binary::binary         # All topic data
              >>

          {context, {:ok, response}}

        # user requested a list of bulletin board post headers beginning with the given date / time
        # select all posts in the bulletin board / topic that were posted since then, or any posts with replies posted since then
        # ... then, we put that list of post_ids into the context for the user to paginate over
        # ... then, we return the first page of post details
        # Replace the existing query in the 0x67, 0x24 case with this:
        <<0, 0, 0x67, 0x24, mon::bytes-size(2), day::bytes-size(2), min::bytes-size(2), hour::bytes-size(2), topic_id::16-big >> ->
          Logger.info("start cursor for bbs topic #{topic_id}")

          # Parse the date/time components
          current_year = Date.utc_today().year
          month = String.to_integer(mon)
          day = String.to_integer(day)
          minute = String.to_integer(min)
          hour = String.to_integer(hour)

          # Build the datetime threshold
          {:ok, threshold_datetime} = NaiveDateTime.new(current_year, month, day, hour, minute, 0)
          threshold_datetime = DateTime.from_naive!(threshold_datetime, "Etc/UTC")

          # Get all matching post IDs - posts created after threshold OR posts with replies after threshold
          post_ids = Repo.all(
            from p in Post,
            left_join: r in Post, on: r.in_reply_to == p.id,
            where: p.topic_id == ^topic_id and is_nil(p.in_reply_to),
            where: p.sent_date >= ^threshold_datetime or r.sent_date >= ^threshold_datetime,
            group_by: p.id,
            order_by: [asc: p.sent_date],
            select: p.id
          )

          # Store cursor in context
          context = Map.merge(context, %{
            bb: %{
              post_ids: post_ids,
              offset: 0,
              topic_id: topic_id,
              current_post_id: nil,  # Track which post we're viewing
              reply_ids: [],         # List of reply IDs for current post
              reply_offset: 0,       # Current position in reply list
              rest: nil
            }
          })

          {context, {:ok, get_index_page(context.bb)}}

        # user requesting to move the cursor over the list of bulletin board post headers
        <<0, 0, 0x67, direction, _mon::bytes-size(2), _day::bytes-size(2), topic_len::16-big, _topic_text::binary-size(topic_len) >> ->
          Logger.info("bbs topic pagination request, direction: #{direction}")

          new_offset = case direction do
            0x01 -> max(0, context.bb.offset - 3)                    # Previous page
            0x02 -> min(context.bb.offset + 3, length(context.bb.post_ids) - 3)  # Next page
            0x10 -> 0                                                 # Reset to beginning
            _ -> context.bb.offset
          end

          new_context = %{context | bb: %{context.bb | offset: new_offset}}

          {new_context, {:ok, get_index_page(new_context.bb)}}

        # User requested the envelope headers and first 280 bytes of a specific post body
        # Update the post viewing case to track current post:
        <<0, 0, 0x68, 0, post_id::16-big >> ->
          Logger.info("bbs request for post #{post_id} (header and 1st page)")

          # get the actual database ID
          actual_post_id = Enum.at(context.bb.post_ids, post_id - 1)
          {response, rest} = get_post_by_id(actual_post_id)

          # Update context with current post and rest
          new_context = %{context | bb: %{context.bb |
            rest: rest,
            current_post_id: actual_post_id
          }}

          {new_context, {:ok, response}}

        # User requested the rest of the post body
        <<0, 0, 0x68, 0x40, post_id::16-big >> ->
          Logger.info("bbs request for post #{post_id} (rest or subsequent?)")

          response = <<
            0x0,        # dunno
            0x0,        # dunno
            byte_size(context.bb.rest)::16-big,
            context.bb.rest::binary
          >>

          # clear the extraneous data from the context
          new_context = %{context | bb: %{context.bb| rest: nil}}

          {new_context, {:ok, response}}

        # User requested replies for the post they're currently looking at, beginning on given date/time stamp
        # get the current post_id from the context, then recursively query for posts "in_reply_to" that post_id
        # store this list in the context as the "reply_ids"
        # store current_reply_offset = 0 in the context
        # Then get and return the envelope headers and first 280 bytes of the reply id stored at current_reply_offset in reply_ids
        # store the rest of the reply body in the context (can reuse "rest" for this since user cached entirety of
        #   post they arrived here from)
        # Replace the placeholder implementation:
        <<0, 0, 0x68, 0x28, 0::16-big, mmdd::binary-size(4), hhmm::binary-size(4) >> ->
          Logger.info("populate reply list, get first reply header and first body page")

          # Parse the date threshold for replies
          month = String.to_integer(binary_part(mmdd, 0, 2))
          day = String.to_integer(binary_part(mmdd, 2, 2))
          hour = String.to_integer(binary_part(hhmm, 0, 2))
          minute = String.to_integer(binary_part(hhmm, 2, 2))

          current_year = Date.utc_today().year
          {:ok, threshold_datetime} = NaiveDateTime.new(current_year, month, day, hour, minute, 0)

          # Get all replies with their dates
          replies_with_dates = get_all_replies_with_dates(context.bb.current_post_id)

          reply_ids = Enum.map(replies_with_dates, & &1.id)

          starting_offset = replies_with_dates
          |> Enum.find_index(fn %{sent_date: date} -> NaiveDateTime.compare(date, threshold_datetime) >= 0 end) || 0

          available_replies = length(reply_ids) - starting_offset

          if available_replies > 0 do
            # Get the first reply at the starting offset
            first_reply_id = Enum.at(reply_ids, starting_offset)
            {response, rest} = get_post_by_id(first_reply_id, starting_offset + 1)

            # Update context with reply list and starting offset
            new_context = %{context | bb: %{context.bb |
              reply_ids: reply_ids,
              reply_offset: starting_offset,  # Start at the first reply >= threshold
              rest: rest
            }}

            {new_context, {:ok, response}}
          else
            # No replies found after threshold
            {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
          end

        # User requested the rest of the reply body
        <<0, 0, 0x68, 0x61>> ->
          Logger.info("get rest of reply body")

          response = <<
            0x0,
            0x0,
            byte_size(context.bb.rest || <<>>)::16-big,
            (context.bb.rest || <<>>)::binary
          >>

          # Clear the rest from context
          new_context = %{context | bb: %{context.bb | rest: nil}}

          {new_context, {:ok, response}}

        # User requested "next reply"; advance "current_reply_offset" in the context
        # Then get and return the envelope headers and first 280 bytes of the reply id stored at current_reply_offset in reply_ids
        # store the rest of the reply body in the context (can reuse "rest" for this since user cached entirety of
        #   post they arrived here from)
        <<0, 0, 0x68, 0x21 >> ->
          Logger.info("get next reply header and first body page")

          # Advance the reply offset
          new_offset = context.bb.reply_offset + 1

          if new_offset < length(context.bb.reply_ids) do
            # Get the next reply
            next_reply_id = Enum.at(context.bb.reply_ids, new_offset)
            {response, rest} = get_post_by_id(next_reply_id, new_offset + 1)

            new_context = %{context | bb: %{context.bb |
              reply_offset: new_offset,
              rest: rest
            }}

            {new_context, {:ok, response}}
          else
            # No more replies
            {context, {:ok, <<0x0, 0x0, 0::16-big>>}}  # Adjust based on protocol
          end
        _ ->
          Logger.warning(
            "unhandled bulletin board request: #{inspect(request, base: :hex, limit: :infinity)}"
          )

          {context, {:ok, <<0>>}}
      end

    case response do
      {:ok, payload} -> {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, context}
    end
  end
end
