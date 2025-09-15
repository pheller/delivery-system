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

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  def handle(%Fm0{payload: <<0x3, payload::binary>>} = request, %Context{} = context) do
    Logger.info("bbs got payload #{inspect(payload, base: :hex, limit: :infinity)}")
    {context, response} =
      case payload do
        << 0, 0, 0x65, bbs_handle::bytes-size(3) >> ->
          Logger.info("got entry message for bbs with handle #{bbs_handle}")
          {context, {:ok, << 0, 0::16, 0::32, 13::16-big, "Computer Club"::binary >>}}
        <<0, 0, 0xF, bbs_handle::bytes-size(3), 0xC>> -> # topics
          Logger.info("got topic request for bbs with handle #{bbs_handle}")
          topic_count=20
          {context, {:ok, << 0x1, 0::16-big, topic_count::16-big, 0::16-big,
            # length n, n bytes             , ?, ?,           topic_id?
            11::16-big, "Programming"::binary, 1, 2::32-big, 1::16-big,
            11::16-big, "PC Industry"::binary, 1, 2::32-big, 2::16-big,
            18::16-big, "Financial Software"::binary, 1, 2::32-big, 3::16-big,
            15::16-big, "Adventure Games"::binary, 1, 2::32-big, 4::16-big,
            11::16-big, "Video Games"::binary, 1, 2::32-big, 5::16-big,
            11::16-big, "Other Games"::binary, 1, 2::32-big, 6::16-big,
            12::16-big, "Mac Software"::binary, 1, 2::32-big, 7::16-big,
            18::16-big, "Word Proc/Desk Pub"::binary, 1, 2::32-big, 8::16-big,
            23::16-big, "Spread Sheets/Databases"::binary, 1, 2::32-big, 9::16-big,
            9::16-big, "Utilities"::binary, 1, 2::32-big, 10::16-big,
            9::16-big, "Beginners"::binary, 1, 2::32-big, 11::16-big,
            17::16-big, "Operating Systems"::binary, 1, 2::32-big, 12::16-big,
            14::16-big, "Communications"::binary, 1, 2::32-big, 13::16-big,
            15::16-big, "Other PC Topics"::binary, 1, 2::32-big, 14::16-big,
            16::16-big, "Hardware:Systems"::binary, 1, 2::32-big, 15::16-big,
            20::16-big, "Hardware:Peripherals"::binary, 1, 2::32-big, 16::16-big,
            8::16-big, "Software"::binary, 1, 2::32-big, 17::16-big,
            12::16-big, "Mac Hardware"::binary, 1, 2::32-big, 18::16-big,
            15::16-big, "User Interfaces"::binary, 1, 2::32-big, 19::16-big,
            19::16-big, "MIDI/Computer Audio"::binary, 1, 2::32-big, 20::16-big
          >>}}

        <<0, 0, 0x67, 0x24, mon::bytes-size(2), day::bytes-size(2), min::bytes-size(2), hour::bytes-size(2), topic_id::16-big >> ->
        # first .... request for messages?
          Logger.info("got message request for bbs topic #{topic_id}")
          #                  success?  ?            offset to first requested message?

          test = <<
            0x1,
            0x0,
            0x0::32-big,
            2::16-big,          # total messages
            2::16-big,          # messages this page

            "0914"::binary,
            "    "::binary,
            0::16-big,
            3::16-big,
            "ALL"::binary,
            14::16-big,
            "Phillip Heller"::binary,
            7::16-big,
            "Testing"::binary,

            "0913"::binary,
            "0914"::binary,
            31::16-big,
            3::16-big,
            "ALL"::binary,
            14::16-big,
            "Phillip Heller"::binary,
            11::16-big,
            "VCF Midwest"::binary
          >>

#          {context, {:ok, << 0x1, 0::40, 1::16-big >>}}
          {context, {:ok, test}}

        # post pagination; direction: 0x1=next, 0x2=back;
        # so we must store the offset in the context
        <<0, 0, 0x67, direction, mon::bytes-size(2), day::bytes-size(2), topic_len::16-big, topic_text::binary-size(topic_len) >> ->
          Logger.info("got post pagination request")
          #
          #  1 to RDA63; anything but 0x02
          #  2 to topic_data_3
          #  3/4/5/6 to topic_data_2
          #  7/8 to RDA63, to an int  - clamped to 2997 which is 9 pages of 333.  post length? then to RDA199
          #  9/10 to RDA63, to an int - to RDA174  - how many posts on this page

          # repeated
          # 11/12 to RDA64 - 2 digit month?
          # 13/14 to RDA66 - 2 digit day?  &20(I2) becomes RDA64."/"RDA66 - maybe original post?

          # 15/16 to RDA64 -
          # 17/18 to RDA66 - &32(I2) becomes RDA64."/"RDA66 - maybe most recent reply?

          # 19/20 to RDA63 - reply count

          # 21/22 to RDA63 to I1 - a length N
          # N bytes to &11(I2) - "TO"
          # 2 bytes to RDA63 to I1 - a length N
          # N bytes to &14(I2) - "FROM"
          # 2 bytes to RDA63 to I1 - a length N
          # N bytes to &17(I2) - "SUBJECT"

          test = <<
            0x1,
            0x0,
            0x0::32-big,
            2::16-big,          # total messages
            2::16-big,          # messages this page

            "0914"::binary,
            "    "::binary,
            0::16-big,
            3::16-big,
            "ALL"::binary,
            14::16-big,
            "Phillip Heller"::binary,
            7::16-big,
            "Testing"::binary,

            "0913"::binary,
            "0914"::binary,
            31::16-big,
            3::16-big,
            "ALL"::binary,
            14::16-big,
            "Phillip Heller"::binary,
            11::16-big,
            "VCF Midwest"::binary
          >>

          {context, {:ok, test}}

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