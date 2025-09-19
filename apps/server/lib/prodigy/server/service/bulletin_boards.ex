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

  @declaration "When in the Course of human events, it\nbecomes necessary for one people to\ndissolve the political bands which have\nconnected them with another, and to\nassume among the powers of the earth,\nthe separate and equal station to which\nthe Laws of Nature and of Nature's God\nentitle them, a decent respect to the\nopinions of mankind requires that they\nshould declare the causes which impel\nthem to the separation.\n\nWe hold these truths to be\nself-evident, that all men are created\nequal, that they are endowed by their\nCreator with certain unalienable\nRights, that among these are Life,\nLiberty and the pursuit of\nHappiness.--That to secure these\nrights, Governments are instituted\namong Men, deriving their just powers\nfrom the consent of the governed,\n--That whenever any Form of Government\nbecomes destructive of these ends, it\nis the Right of the People to alter or\nto abolish it, and to institute new\nGovernment, laying its foundation on\nsuch principles and organizing its\npowers in such form, as to them shall\nseem most likely to effect their Safety\nand Happiness. Prudence, indeed, will\ndictate that Governments long\nestablished should not be changed for\nlight and transient causes; and\naccordingly all experience hath shewn,\nthat mankind are more disposed to\nsuffer, while evils are sufferable,\nthan to right themselves by abolishing\nthe forms to which they are accustomed.\nBut when a long train of abuses and\nusurpations, pursuing invariably the\nsame Object evinces a design to reduce\nthem under absolute Despotism, it is\ntheir right, it is their duty, to throw\noff such Government, and to provide new\nGuards for their future security.--Such\nhas been the patient sufferance of\nthese Colonies; and such is now the\nnecessity which constrains them to\nalter their former Systems of\nGovernment. The history of the present\nKing of Great Britain is a history of\nrepeated injuries and usurpations, all\nhaving in direct object the\nestablishment of an absolute Tyranny\nover these States. To prove this, let\nFacts be submitted to a candid world."

  defp format_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      String.pad_trailing(line, 40)
    end)
  end

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
      10000::64-big,                    # dunno
      (post.in_reply_to || 0)::16-big,
      (post.reply_count || 0)::16-big,
      0,                                # dunno
      0::16-big,                        # dunno
      byte_size(post.topic.title)::16-big,
      post.topic.title::binary,
      byte_size(to_name)::16-big,
      to_name::binary,
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

    lines = format_lines(@declaration)
    first = Enum.take(lines, 7) |> Enum.join
    rest = Enum.drop(lines, 7) |> Enum.join
    _total = byte_size(first) + byte_size(rest)


    Logger.info("bbs got payload #{inspect(payload, base: :hex, limit: :infinity)}")
    {context, response} =
      case payload do
        << 0, 0, 0x65, bbs_handle::bytes-size(3) >> ->
          club = Repo.get_by(Club, handle: bbs_handle)
          response = case club do
            nil ->
              Logger.error("Club with handle #{bbs_handle} not found")
              << 0, 0xFF::16, 0::32, 0::16-big >>
            %Club{name: name} ->
              << 0, 0::16, 0::32, byte_size(name)::16-big, name::binary >>
          end
          {context, {:ok, response}}


        <<0, 0, 0xF, bbs_handle::bytes-size(3), 0xC>> -> # topics
          Logger.info("got topic request for bbs with handle #{bbs_handle}")

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

        # first request for bulletin posts - establishes a cursor
        #              v-- do not include older bulletins with replies since given date
        #         v------- get bulletins
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

          # TODO assuming 1k posts and a 4 byte id, this will store 4k in the context for the user
          #   if we instead did a limit/offset query each time, that would require only offset be stored, but if could
          #   be inconsistent if a new post were made that matches the filter criteria - we send the total count on
          #   the initial request

          {context, {:ok, get_index_page(context.bb)}}

        # subsequent request for bulletin posts - navigate over cursor, store position in context
        # post pagination; direction: 0x1=next, 0x2=back; 0x16=reset?
        #                 v--- pagination direction: 0x1=next, 0x2=prev
        #         v----------- get bulletins
        <<0, 0, 0x67, direction, _mon::bytes-size(2), _day::bytes-size(2), topic_len::16-big, _topic_text::binary-size(topic_len) >> ->
          Logger.info("bbs topic pagination request")

          new_offset = case direction do
            0x01 -> context.bb.offset - 3
            0x02 -> context.bb.offset + 3
            0x10 -> 0
          end

          new_context = %{context | bb: %{context.bb| offset: new_offset}}

          {new_context, {:ok, get_index_page(new_context.bb)}}


        # Ok, so, the way content is returned, it seems that the rendering doesn't respect
        # any formatting characters like \n.  So, it seems that bulletin posts probably filled
        # every line with whitespace in lieu of \n.
        #
        # so when the RS wants a single post, they ask for it by post_id.  the header fields are
        # returned along with, ideally, the first page of data.  That can be up to 7 lines, 40
        # columns each.
        #
        # If we are economizing on database space and storing \n instead of all the white space,
        # then we need to split on \n, fill lines to 40 chars with whitespace, then join the lines.
        #
        # THis means for the first page, we would return 7*40=280 bytes exactly  (or less if only one page)
        # and the rest in the second call that follows.
        #
        # One important thing - we obviously need to cache the current topic index map to
        # translate to database table id column values.  Should we also cache the "rest" of a
        # post in the context so that we only hit the database one time for each message?  Seems
        # like a good idea.

        # Retrieve single post header & first page
        <<0, 0, 0x68, 0, post_id::16-big >> ->
          Logger.info("bbs request for post #{post_id} (header and 1st page)")

          # get the index at post-1, because the server list is 0 indexed
          {response, rest} = get_post_by_id(Enum.at(context.bb.post_ids, post_id-1))

          # TODO is this a good idea?  store the rest of the post in the cursor?  We know the user will request
          #   it immediately, and this saves another database round-trip

          new_context = %{context | bb: %{context.bb| rest: rest}}

          {new_context, {:ok, response}}

        # Retrieve rest of post
        <<0, 0, 0x68, 0x40, post_id::16-big >> ->
          Logger.info("bbs request for post #{post_id} (rest or subsequent?)")

          response = <<
            0x0,        # dunno
            0x0,        # dunno
            byte_size(context.bb.rest)::16-big,
            context.bb.rest::binary
          >>

          new_context = %{context | bb: %{context.bb| rest: nil}}

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
