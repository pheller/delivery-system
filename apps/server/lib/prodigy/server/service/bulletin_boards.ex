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

  def get_post_by_id(id) do
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

    to_name = if is_nil(post.to_name) or post.to_name == "", do: "ALL", else: post.to_name


    {first, rest} = case post.body do
      <<first::binary-size(280), rest::binary>> -> {first, rest}
      body -> {body, <<>>}
    end

    response = <<
      0x0,                              # 0x02 goes to safepage
      0x0,                              # skips some reply related stuff? dunno
      post.from_id::binary,             # fixed 7 bytes
      sent_mmdd::binary,
      last_mmdd::binary,
      sent_mmdd::binary-size(4), sent_hhmm_24hr::binary-size(4),  #   (post timestamp?)
      (post.in_reply_to || 0)::16-big,  # TODO - nope!  This looks like it needs to be the integer sequence of reply to the post.  e.g., first reply is 1, second is 2.
#      1,
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

          # Get all matching post IDs (only top-level posts)
          post_ids = Post
            |> where([p], p.topic_id == ^topic_id)
            |> where([p], is_nil(p.in_reply_to))
            |> where([p], p.sent_date >= ^threshold_datetime)
            |> order_by([p], asc: p.sent_date)
            |> select([p], p.id)
            |> Repo.all()

          # Store cursor in context
          context = Map.merge(context, %{
            bb: %{
              post_ids: post_ids,
              offset: 0,
              topic_id: topic_id,
              rest: nil
            }
          })

          {context, {:ok, get_index_page(context.bb)}}

        # user requesting to move the cursor over the list of bulletin board post headers
        <<0, 0, 0x67, direction, _mon::bytes-size(2), _day::bytes-size(2), topic_len::16-big, _topic_text::binary-size(topic_len) >> ->
          Logger.info("bbs topic pagination request")

          new_offset = case direction do
            0x01 -> context.bb.offset + 3   # TODO something funky here when doing "read all", then going to select more bulletins
            0x02 -> context.bb.offset - 3   # TODO ... or here.
            0x10 -> 0
          end

          new_context = %{context | bb: %{context.bb| offset: new_offset}}

          {new_context, {:ok, get_index_page(new_context.bb)}}

        # User requested the envelope headers and first 280 bytes of a specific post body
        <<0, 0, 0x68, 0, post_id::16-big >> ->
          Logger.info("bbs request for post #{post_id} (header and 1st page)")

          # get the index at post-1, because the context list is 0 indexed whereas the client is 1 indexed
          {response, rest} = get_post_by_id(Enum.at(context.bb.post_ids, post_id-1))

          # store the remaining post body (anything after first 280 bytes) in the context because the
          # user will ask for it in their very next call.  This saves an extra database query.
          new_context = %{context | bb: %{context.bb| rest: rest}}

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
        <<0, 0, 0x68, 0x28, 0::16-big, mmdd::binary-size(4), hhmm::binary-size(4) >> ->
          Logger.info("populate reply list, get first reply header and first body page")

          #mmdd and hhmm are the "read replies since" values.

          {response, rest} = get_post_by_id(3)

          {context, {:ok, response}}

        # User requested the rest of the reply body
        <<0, 0, 0x68, 0x61>> ->
          Logger.info("get rest of reply body")

          {context, {:ok, << 0 >>}}

        # User requested "next reply"; advance "current_reply_offset" in the context
        # Then get and return the envelope headers and first 280 bytes of the reply id stored at current_reply_offset in reply_ids
        # store the rest of the reply body in the context (can reuse "rest" for this since user cached entirety of
        #   post they arrived here from)
        <<0, 0, 0x68, 0x21 >> ->
          Logger.info("get next reply header and first body page")

          # get the index at post-1, because the server list is 0 indexed
          {response, rest} = get_post_by_id(4)

          new_context = %{context | bb: %{context.bb| rest: rest}}

          {new_context, {:ok, response}}

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
