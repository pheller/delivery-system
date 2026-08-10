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
  # ZZDJ0091 sends "HI400010"+..+'1'+<mode>+'  '+name; the picker (ZZDJ0065WND
  # via ZZDJ0070) parses our reply as:
  #   status(1)='0' | reserved(6) | page-count(2) | total(5) | token(5) | rows
  #   each row = [2-byte-binary content-len][5-char ticker][1 sep][name]
  # The mode byte drives the two search levels:
  #   '0'  -> GROUP mode: return fund-family group names (ticker field unused;
  #           the client re-queries members by the selected group NAME).
  #   else -> SYMBOL rows ('1'/'5'/'8' = direct name search, '9' = members of a
  #           picked group).
  # MOCK: synthetic results derived from the search term. Replace the `matches`
  # computation with a real host-index database lookup to hook this to reality.
  def handle(
        %Fm0{dest: 0x040210, payload: <<"HI400010", rest::binary>>} = request,
        %Context{} = context
      ) do
    # Query body is '1' + mode + '  ' + name (after the HI400010 descriptor/len);
    # the mode is the last char before the double-space separator.
    {mode, name} =
      case String.split(to_string(rest), "  ", parts: 2) do
        [prefix, nm] -> {String.last(prefix), nm |> String.trim() |> String.upcase()}
        _ -> {nil, ""}
      end

    Logger.info("dow_jones host-index search: mode=#{inspect(mode)} name=#{inspect(name)}")

    matches =
      cond do
        name == "" ->
          []

        mode == "0" ->
          # GROUP mode: a handful of fund families (single page). Ticker field is
          # unused for group rows, so a placeholder is fine.
          ["FUNDS", "FAMILY OF FUNDS", "GROUP", "INDEX TRUST", "PARTNERS"]
          |> Enum.with_index()
          |> Enum.map(fn {suffix, i} -> {"GRP" <> <<?A + i>> <> "0", "#{name} #{suffix}"} end)

        true ->
          # SYMBOL / member mode: real tickers + names. 10 rows -> 3 picker pages
          # (4+4+2) so NEXT/BACK paging is exercised (both active on the middle).
          base = name |> String.replace(~r/[^A-Z0-9]/, "") |> String.slice(0, 4)

          [
            "MOCK CORP",
            "HOLDINGS INC",
            "INDUSTRIES",
            "TECHNOLOGIES",
            "GROWTH FUND",
            "INCOME FUND",
            "VALUE FUND",
            "INDEX FUND",
            "GLOBAL FUND",
            "BALANCED FUND"
          ]
          |> Enum.with_index()
          |> Enum.map(fn {desc, i} -> {"#{base}#{<<?A + i>>}", "#{name} #{desc}"} end)
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

  # HI500010 host-index (0x040210): quote-track saved lists. This is the WRITE
  # side's backend as well as quote-track's read side. Stateful (ETS now, keyed
  # per user; Postgres later). The wire message is:
  #   descriptor(18) = "HI500010" <> "00012Y" <> <<0,0,0,0>>
  #   <> <<bodylen>> <> body
  # where body starts with a 2-char op code (ZDJ0006A GOTO_DEPENDING_ON P1 is
  # 1-indexed: '01' load, '03' save, '04' delete):
  #   '01' load   : "01" <> uid(7) <> P2         -> return all the user's lists
  #   '03' save   : "03" <> uid(7) <> listname   then a trailing 0x00 flag and a
  #                 1-byte-length-prefixed symbols blob (N x 6 bytes: type(1) +
  #                 ticker(5, space-padded)) -> replace that list's symbols
  #   '04' delete : "04" <> uid(7) <> ticker     -> drop the symbol from the list
  # ZDJ0006B parses the '01' response: status(1)='0' | reserved(6) | count(2) |
  # per-list entry, each = [2-byte-binary len][2-digit name-len][name][6-byte
  # symbols]. The client keys lists by SYS_NAVIGATE_KEYWORD ("QUOTE TRACK 1/2").
  def handle(
        %Fm0{dest: 0x040210, payload: <<"HI500010", _desc::binary-size(10), body::binary>>} =
          request,
        %Context{} = context
      ) do
    <<_bodylen, op::binary-size(2), rest::binary>> = body
    user_id = context.user.id

    payload =
      case op do
        "01" ->
          Logger.info("dow_jones HI500010 list load (MOCK) user=#{user_id}")
          hi500010_load_payload(user_id)

        "02" ->
          # Maint single-list load: "02" <> "23" <> "15" <> uid(7) <> listname.
          <<_p1::binary-size(2), _p2::binary-size(2), _uid::binary-size(7),
            listname::binary>> = rest
          Logger.info("dow_jones HI500010 load-one (MOCK) user=#{user_id} " <>
            "list=#{inspect(listname)}")
          hi500010_loadone_payload(user_id, listname)

        "03" ->
          # rest = uid(7) <> listname <> <<0x00, len2, symbols::size(len2)>>. The
          # bodylen only covered "03"+uid+listname, so split listname at the 0x00.
          <<_uid::binary-size(7), tail::binary>> = rest
          [listname, sympart] = :binary.split(tail, <<0x00>>)
          <<len2, symblob::binary-size(len2)>> = sympart
          syms = parse_symbols(symblob)
          Logger.info("dow_jones HI500010 save (MOCK) user=#{user_id} " <>
            "list=#{inspect(listname)} syms=#{inspect(syms)}")
          put_list(user_id, listname, syms)
          "0" <> String.duplicate(" ", 6) <> "00"

        "04" ->
          <<_uid::binary-size(7), delsym::binary>> = rest
          ticker = delsym |> String.slice(0, 6) |> String.replace_prefix("1", "") |> String.trim()
          Logger.info("dow_jones HI500010 delete (MOCK) user=#{user_id} sym=#{inspect(ticker)}")
          delete_symbol(user_id, ticker)
          "0" <> String.duplicate(" ", 6) <> "00"

        other ->
          Logger.warning("dow_jones HI500010 unknown op #{inspect(other)} (MOCK)")
          "0" <> String.duplicate(" ", 6) <> "00"
      end

    response = %{
      request
      | concatenated: false,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm9: nil,
        fm64: nil,
        payload: payload
    }

    {:ok, context, DiaPacket.encode(response)}
  end

  # Batch quote (quote-track, DJ 0x067201): payload = [type][5-char sym + space]xN
  # [0x0D] with type ',' (0x2C stock) / '/' (0x2F bond) / '+' (0x2B fund). Reply is
  # concatenated per-symbol entries [1-byte len][field-code 0x04][flag 0x00]
  # [change 9][open 10][high 10][low 10][last 10][volume 10], each rendered by the
  # row program ZDJA0012. Must sit AFTER the single-symbol clauses (guarded on
  # length so a 7-byte single quote never lands here).
  def handle(%Fm0{payload: <<op, body::binary>>} = request, %Context{} = context)
      when op in [0x2C, 0x2F, 0x2B, 0x2D] and byte_size(body) >= 7 do
    symbols =
      body
      |> String.trim_trailing(<<0x0D>>)
      |> to_charlist()
      |> Enum.chunk_every(6)
      |> Enum.map(fn c -> c |> Enum.take(5) |> to_string() |> String.trim() end)
      |> Enum.reject(&(&1 == ""))

    Logger.info("dow_jones batch quote (MOCK): #{inspect(symbols)}")

    entries =
      for sym <- symbols, into: "" do
        {chg, opn, hi, lo, last, vol} =
          try do
            q = decode_quote(sym)

            {fnum(q.regularMarketChange, 9), fnum(q.regularMarketOpen, 10),
             fnum(q.regularMarketDayHigh, 10), fnum(q.regularMarketDayLow, 10),
             fnum(q.regularMarketPrice, 10),
             fstr(Number.Delimit.number_to_delimited(q.regularMarketVolume), 10)}
          rescue
            _ -> {fstr("", 9), fstr("", 10), fstr("", 10), fstr("", 10), fstr("", 10), fstr("", 10)}
          end

        content = <<0x04, 0x00>> <> chg <> opn <> hi <> lo <> last <> vol
        <<byte_size(content)::8>> <> content
      end

    response = %{
      request
      | concatenated: true,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        payload: entries
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

  # Fixed-width field formatters for batch-quote rows. Values are RIGHT-justified
  # in their w-column slots so last/change/volume line up under their headers
  # (ZDJA0012 reads each from a fixed offset; right-justify aligns the columns).
  defp fnum(n, w) do
    :io_lib.format("~.2f", [n * 1.0]) |> List.to_string() |> fstr(w)
  end

  defp fstr(s, w) do
    s |> to_string() |> String.slice(0, w) |> String.pad_leading(w)
  end

  # --- HI500010 quote-track saved-list store (per-user, ETS) -----------------
  # Seeded on first read so quote-track shows data offline; LIST 1 has 12 symbols
  # (3 pages) to exercise paging. Keyed {:qt_list, user_id, name} in :dow_jones.
  @qt_default_lists %{
    "QUOTE TRACK 1" =>
      for(s <- ~w(IBM GM AAPL MSFT XRX GT F KO GE HPQ INTC T), do: {"1", s}),
    "QUOTE TRACK 2" => [{"1", "MSFT"}, {"1", "XRX"}, {"1", "GT"}]
  }
  @qt_list_names ["QUOTE TRACK 1", "QUOTE TRACK 2"]

  defp qt_key(user_id, name), do: {:qt_list, user_id, name}

  defp get_list(user_id, name) do
    case :ets.lookup(:dow_jones, qt_key(user_id, name)) do
      [{_, syms}] ->
        syms

      [] ->
        seed = Map.get(@qt_default_lists, name, [])
        :ets.insert(:dow_jones, {qt_key(user_id, name), seed})
        seed
    end
  end

  defp put_list(user_id, name, syms) do
    :ets.insert(:dow_jones, {qt_key(user_id, name), syms})
  end

  defp delete_symbol(user_id, ticker) do
    @qt_list_names
    |> Enum.each(fn name ->
      syms = get_list(user_id, name)
      kept = Enum.reject(syms, fn {_t, s} -> s == ticker end)
      if kept != syms, do: put_list(user_id, name, kept)
    end)
  end

  # 6-byte symbol records: type(1) + ticker(5, space-padded). Trim to {type, tick}.
  defp parse_symbols(blob) do
    for <<chunk::binary-size(6) <- blob>> do
      <<type::binary-size(1), tick::binary-size(5)>> = chunk
      {type, String.trim(tick)}
    end
    |> Enum.reject(fn {_t, s} -> s == "" end)
  end

  # '02' maint load-one response (one named list, with resolved names):
  #   status(1)='0' | reserved(6) | flag(1)='0' | count(2, ASCII) | per-symbol
  #   [2-byte-binary len][type(1)][ticker(5, space-padded)][name]. BNB00002
  #   proc_1 reads flag@8, count@9-10, entries@11. Names aren't persisted by the
  #   '03' save (type+ticker only), so the server resolves each here.
  defp hi500010_loadone_payload(user_id, listname) do
    syms = get_list(user_id, listname)

    entries =
      for {t, s} <- syms, into: "" do
        name = qt_short_name(s)
        content = t <> String.pad_trailing(String.slice(s, 0, 5), 5) <> name
        <<byte_size(content)::16>> <> content
      end

    count = syms |> length() |> Integer.to_string() |> String.pad_leading(2, "0")
    "0" <> String.duplicate(" ", 6) <> "0" <> count <> entries
  end

  # Display name for a ticker: ETS name cache, else decode_quote, else the ticker.
  defp qt_short_name(ticker) do
    case :ets.lookup(:dow_jones, ticker) do
      [{_, name}] ->
        name

      [] ->
        try do
          (decode_quote(ticker).shortName || ticker) |> to_string() |> String.upcase()
        rescue
          _ -> ticker
        end
    end
  end

  # '01' load response: status + reserved + count + one entry per list.
  defp hi500010_load_payload(user_id) do
    lists = for name <- @qt_list_names, do: {name, get_list(user_id, name)}

    entries =
      for {name, syms} <- lists, into: "" do
        sym_bin =
          for {t, s} <- syms, into: "", do: t <> String.pad_trailing(String.slice(s, 0, 5), 5)

        content =
          String.pad_leading(Integer.to_string(byte_size(name)), 2, "0") <> name <> sym_bin

        <<byte_size(content)::16>> <> content
      end

    count = lists |> length() |> Integer.to_string() |> String.pad_leading(2, "0")
    "0" <> String.duplicate(" ", 6) <> count <> entries
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
