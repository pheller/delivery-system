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

defmodule Prodigy.Server.Service.DowJones do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Dow Jones requests
  """

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm64}
  alias Prodigy.Server.Context

  defmodule QuoteData do
    @moduledoc false
    defstruct quoteResponse: nil
  end

  defmodule Response do
    @moduledoc false
    defstruct result: []
  end

  defmodule Quote do
    @moduledoc false
    defstruct shortName: nil,
              regularMarketChange: nil,
              regularMarketDayHigh: nil,
              regularMarketDayLow: nil,
              regularMarketOpen: nil,
              regularMarketPrice: nil,
              regularMarketVolume: nil
  end

  defp decode_quote(symbol) do
    # Task.async_nolink so a crash in the upstream HTTP work doesn't
    # propagate via process link and kill the per-connection handler
    # (CM4 / "carrier loss" on the client). Task.shutdown after yield
    # ensures any task that took longer than the 6s deadline is
    # actively killed instead of left orphaned to crash later.
    task = Task.Supervisor.async_nolink(Prodigy.Server.TaskSup, fn -> get_quote(symbol) end)

    json =
      case Task.yield(task, 6_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {_symbol, json}}} ->
          json

        {:ok, {:error, reason}} ->
          raise RuntimeError, message: "DowJones API error: #{inspect(reason)}"

        {:exit, reason} ->
          raise RuntimeError, message: "DowJones API task exit: #{inspect(reason)}"

        nil ->
          raise RuntimeError, message: "DowJones API timeout"
      end

    quote_data =
      Poison.decode!(json, as: %QuoteData{quoteResponse: %Response{result: [%Quote{}]}})

    Enum.at(quote_data.quoteResponse.result, 0)
  end

  defp get_quote(symbol) do
    Prodigy.Server.Service.DowJones.Api.custom_quote(String.trim(symbol), [
      :longName,
      :shortName,
      :regularMarketChange,
      :regularMarketOpen,
      :regularMarketDayHigh,
      :regularMarketDayLow,
      :regularMarketPrice,
      :regularMarketVolume
    ])
  end

  @doc """
  This method handles Stock Symbol to Company Name resolution requests from the newly created logic in BNB00037.PGM.
  """
  def handle(%Fm0{dest: 0x009900, payload: symbol} = request, %Context{} = context) do
    Logger.info("dow jones resolve symbol '#{symbol}' to short name")

    shortName =
      try do
        case(:ets.lookup(:dow_jones, symbol)) do
          [{_key, value}] ->
            value

          _ ->
            quote = decode_quote(symbol)
            # All-caps to match the original Prodigy display convention
            # (1990s ticker pages were rendered in uppercase).
            short_name = (quote.shortName || symbol) |> to_string() |> String.upcase()
            Logger.info("Symbol #{symbol} not found in table, adding as '#{short_name}'.")
            :ets.insert_new(:dow_jones, {symbol, short_name})
            short_name
        end
      rescue
        e ->
          Logger.warning(
            "dow_jones symbol-resolve failed for '#{symbol}': #{Exception.message(e)}"
          )

          # Echo the symbol back as the "short name" so the client gets
          # a non-empty response and the connection survives. The user
          # sees the raw ticker rather than a friendly name; better
          # than CM4-ing them off the service.
          symbol
      end

    Logger.debug("short name is #{shortName}")

    response = %{
      request
      | concatenated: false,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm9: nil,
        fm64: nil,
        payload: shortName
    }

    {:ok, context, DiaPacket.encode(response)}
  end

  def handle(
        %Fm0{dest: _dest, payload: <<0x2C, symbol::binary-size(5), 0xD>>} = request,
        %Context{user: _user} = context
      ) do
    Logger.debug("dow jones request #{inspect(request, base: :hex, limit: :infinity)}")

    response =
      try do
        quote = decode_quote(symbol)
        short_name = (quote.shortName || symbol) |> to_string() |> String.upcase()
        :ets.insert_new(:dow_jones, {symbol, short_name})

        data =
          List.to_string(
            :io_lib.format(
              "~-10.2f~-10.2f~-10.2f~-10.2f~-10.2f~-10.s",
              [
                quote.regularMarketChange,
                quote.regularMarketOpen,
                quote.regularMarketDayHigh,
                quote.regularMarketDayLow,
                quote.regularMarketPrice,
                Number.Delimit.number_to_delimited(quote.regularMarketVolume)
              ]
            )
          )

        %{
          request
          | concatenated: true,
            src: request.dest,
            dest: request.src,
            mode: %Fm0.Mode{response: true},
            payload: <<0x3D, 0x04, 0x0>> <> data
        }
      rescue
        # TODO shouldn't be this broad in catching errors
        e ->
          Logger.warning(
            "dow_jones quote failed for '#{symbol}': #{Exception.message(e)}"
          )
          # ok, sending statustype INFORMATION or ERROR shows XXME47F4D\x01\x0c to the client
          fm64 = %Fm64{
            concatenated: false,
            status_type: Fm64.StatusType.ERROR,
            data_mode: Fm64.DataMode.BINARY,
            # action, message 41 - timeout
            payload: <<"A", "DJI00001", 0x1::16-big>>
          }

          # payload: << "W", "DJI00001", 0x0::16-big >>} # wait, message 0 - supposed to be "maximum resources in use"
          %{
            request
            | concatenated: true,
              src: request.dest,
              dest: request.src,
              mode: %Fm0.Mode{response: true},
              fm4: nil,
              fm64: fm64,
              payload: <<>>
          }
      end

    {:ok, context, DiaPacket.encode(response)}
  end

  # Mutual fund quote (opcode 0x2B '+'): only NAV (close) and volume are
  # meaningful; open/high/low/last render blank (see +DBURX reference). Reuses
  # field-code 0x04 so the client renders it through the same program (ZZDJ0122)
  # as a stock.
  def handle(
        %Fm0{dest: _dest, payload: <<0x2B, symbol::binary-size(5), 0xD>>} = request,
        %Context{} = context
      ) do
    response =
      try do
        quote = decode_quote(symbol)
        short_name = (quote.shortName || symbol) |> to_string() |> String.upcase()
        :ets.insert_new(:dow_jones, {symbol, short_name})
        blank = String.duplicate(" ", 10)

        data =
          List.to_string(:io_lib.format("~-10.2f", [quote.regularMarketPrice])) <>
            blank <>
            blank <>
            blank <>
            blank <>
            List.to_string(
              :io_lib.format("~-10.s", [
                Number.Delimit.number_to_delimited(quote.regularMarketVolume)
              ])
            )

        %{
          request
          | concatenated: true,
            src: request.dest,
            dest: request.src,
            mode: %Fm0.Mode{response: true},
            payload: <<0x3D, 0x04, 0x0>> <> data
        }
      rescue
        e ->
          Logger.warning("dow_jones fund quote failed for '#{symbol}': #{Exception.message(e)}")
          dj_quote_error(request)
      end

    {:ok, context, DiaPacket.encode(response)}
  end

  # Stock-option quote (opcode 0x2D '-'): full field set, same shape as a stock
  # (see -GMCO reference).
  def handle(
        %Fm0{dest: _dest, payload: <<0x2D, symbol::binary-size(5), 0xD>>} = request,
        %Context{} = context
      ) do
    response =
      try do
        quote = decode_quote(symbol)
        short_name = (quote.shortName || symbol) |> to_string() |> String.upcase()
        :ets.insert_new(:dow_jones, {symbol, short_name})

        data =
          List.to_string(
            :io_lib.format(
              "~-10.2f~-10.2f~-10.2f~-10.2f~-10.2f~-10.s",
              [
                quote.regularMarketChange,
                quote.regularMarketOpen,
                quote.regularMarketDayHigh,
                quote.regularMarketDayLow,
                quote.regularMarketPrice,
                Number.Delimit.number_to_delimited(quote.regularMarketVolume)
              ]
            )
          )

        %{
          request
          | concatenated: true,
            src: request.dest,
            dest: request.src,
            mode: %Fm0.Mode{response: true},
            payload: <<0x3D, 0x04, 0x0>> <> data
        }
      rescue
        e ->
          Logger.warning(
            "dow_jones option quote failed for '#{symbol}': #{Exception.message(e)}"
          )

          dj_quote_error(request)
      end

    {:ok, context, DiaPacket.encode(response)}
  end

  # Bond quote (opcode 0x2F '/'): no reference screenshot exists, so this is a
  # best-guess modeled on the stock shape (full field set). Revisit if a real
  # bond example turns up.
  def handle(
        %Fm0{dest: _dest, payload: <<0x2F, symbol::binary-size(5), 0xD>>} = request,
        %Context{} = context
      ) do
    response =
      try do
        quote = decode_quote(symbol)
        short_name = (quote.shortName || symbol) |> to_string() |> String.upcase()
        :ets.insert_new(:dow_jones, {symbol, short_name})

        data =
          List.to_string(
            :io_lib.format(
              "~-10.2f~-10.2f~-10.2f~-10.2f~-10.2f~-10.s",
              [
                quote.regularMarketChange,
                quote.regularMarketOpen,
                quote.regularMarketDayHigh,
                quote.regularMarketDayLow,
                quote.regularMarketPrice,
                Number.Delimit.number_to_delimited(quote.regularMarketVolume)
              ]
            )
          )

        %{
          request
          | concatenated: true,
            src: request.dest,
            dest: request.src,
            mode: %Fm0.Mode{response: true},
            payload: <<0x3D, 0x04, 0x0>> <> data
        }
      rescue
        e ->
          Logger.warning("dow_jones bond quote failed for '#{symbol}': #{Exception.message(e)}")
          dj_quote_error(request)
      end

    {:ok, context, DiaPacket.encode(response)}
  end

  # HFH host-index query (DID 0x040210): DJ company/fund name search. Client
  # ZZDJ0091 sends "HI400010"+..+'1'+mode+'  '+name; the picker (ZZDJ0065WND via
  # ZZDJ0070) parses our reply as:
  #   status(1)='0' | reserved(6) | page-count(2) | total(5) | token(5) | rows
  #   each row = [2-digit content-len][5-char ticker][1 sep][name]
  # MOCK: up to 3 synthetic matches derived from the search term (single-level;
  # symbol rows only, so the group drill-down stays dormant). Real host-index DB
  # can replace this later.
  def handle(
        %Fm0{dest: 0x040210, payload: <<"HI400010", rest::binary>>} = request,
        %Context{} = context
      ) do
    name =
      rest
      |> to_string()
      |> String.split("  ", parts: 2)
      |> List.last()
      |> String.trim()
      |> String.upcase()

    Logger.info("dow_jones host-index name search: #{inspect(name)}")

    matches =
      if name == "" do
        []
      else
        base = name |> String.replace(~r/[^A-Z0-9]/, "") |> String.slice(0, 4)

        # 10 synthetic matches -> 3 picker pages (4+4+2) so NEXT/BACK paging is
        # exercised (both active on the middle page).
        descriptors = [
          "MOCK CORP",
          "HOLDINGS INC",
          "INDUSTRIES",
          "TECHNOLOGIES",
          "GROUP",
          "PARTNERS",
          "SYSTEMS",
          "ENTERPRISES",
          "GLOBAL",
          "CAPITAL"
        ]

        for {desc, i} <- Enum.with_index(descriptors) do
          {"#{base}#{<<?A + i>>}", "#{name} #{desc}"}
        end
      end

    rows =
      for {ticker, cname} <- matches, into: "" do
        content = String.pad_trailing(String.slice(ticker, 0, 5), 5) <> " " <> cname
        # Per-row length is a 2-byte BINARY integer (client reads it via MOVE ABS),
        # unlike the ASCII header counts.
        <<byte_size(content)::16>> <> content
      end

    count = length(matches)

    header =
      "0" <>
        String.duplicate(" ", 6) <>
        (count |> Integer.to_string() |> String.pad_leading(2, "0")) <>
        (count |> Integer.to_string() |> String.pad_leading(5, "0")) <>
        String.duplicate(" ", 5)

    response = %{
      request
      | concatenated: false,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm9: nil,
        fm64: nil,
        payload: header <> rows
    }

    {:ok, context, DiaPacket.encode(response)}
  end

  # Catch-all for Dow Jones transactions we don't model yet (the maint
  # list-state HI500010 loader, quote-track saved-list load/store, etc).
  #
  # MOCK: log the full request wire format so each transaction can be mapped
  # precisely, and return a graceful "success / no data" reply so the client
  # degrades to empty lists offline instead of CM4-ing the connection.
  #
  # The reply's first byte is "0" (the OK status the client's ZZDJ0007 checks)
  # followed by a zeroed body whose 8th/9th bytes read as a "00" list count;
  # this is best-effort until the layout is confirmed against a live capture.
  # Replace with specific handle/2 clauses as each txn is mapped from the logs.
  def handle(%Fm0{} = request, %Context{} = context) do
    Logger.info(
      "dow_jones UNMODELED txn (MOCK): dest=#{inspect(request.dest, base: :hex)} " <>
        "payload=#{inspect(request.payload, base: :hex, limit: :infinity)}"
    )

    response = %{
      request
      | concatenated: false,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm9: nil,
        fm64: nil,
        payload: <<"0", 0::48, "00">>
    }

    {:ok, context, DiaPacket.encode(response)}
  end

  # Shared FM64 error reply for a failed quote lookup.
  defp dj_quote_error(request) do
    fm64 = %Fm64{
      concatenated: false,
      status_type: Fm64.StatusType.ERROR,
      data_mode: Fm64.DataMode.BINARY,
      payload: <<"A", "DJI00001", 0x1::16-big>>
    }

    %{
      request
      | concatenated: true,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm64: fm64,
        payload: <<>>
    }
  end
end
