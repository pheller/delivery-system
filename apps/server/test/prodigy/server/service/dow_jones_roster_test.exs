defmodule Prodigy.Server.Service.DowJonesRosterTest do
  @moduledoc """
  The Elixir mocks and the quote sidecar must carry the same companies.

  Quotes come from `dowjones_sidecar/app.py`; company news, search and the
  seeded Quote Track lists come from `DowJones`. Nothing makes them agree, so a
  company added to one and not the other gives a symbol that searches but does
  not quote, or quotes but cannot be found - the kind of split that looks like
  a server fault from the client.

  Both are STOPGAP fixtures. When a real quote feed lands, this test goes with
  them.
  """
  use ExUnit.Case, async: true

  @sidecar Path.join([__DIR__, "..", "..", "..", "..", "..", "..", "dowjones_sidecar", "app.py"])

  defp sidecar_symbols do
    @sidecar
    |> File.read!()
    |> String.split("COMPANIES = {", parts: 2)
    |> List.last()
    |> String.split("\n}", parts: 2)
    |> List.first()
    |> then(&Regex.scan(~r/^\s*"([A-Z]+)":/m, &1))
    |> Enum.map(fn [_, sym] -> sym end)
    |> MapSet.new()
  end

  defp elixir_symbols do
    Prodigy.Server.Service.DowJones.roster()
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  test "the sidecar file is where this test thinks it is" do
    assert File.exists?(@sidecar), "expected the sidecar at #{@sidecar}"
  end

  test "every company quotes and every quotable company is known here" do
    sidecar = sidecar_symbols()
    elixir = elixir_symbols()

    assert MapSet.size(sidecar) > 0, "parsed no symbols out of the sidecar"

    assert MapSet.difference(elixir, sidecar) |> MapSet.to_list() == [],
           "known here but the sidecar will not quote them"

    assert MapSet.difference(sidecar, elixir) |> MapSet.to_list() == [],
           "the sidecar quotes them but nothing here knows their name"
  end

  test "the seeded Quote Track lists only hold symbols that quote" do
    sidecar = sidecar_symbols()

    for {list, entries} <- Prodigy.Server.Service.DowJones.default_lists(),
        {_kind, sym} <- entries do
      assert MapSet.member?(sidecar, sym),
             "#{list} seeds #{sym}, which the sidecar does not carry"
    end
  end

  test "no real company names" do
    # A guard against the thing this fixture exists to avoid. Not exhaustive -
    # it catches a paste of the names that were actually here before.
    names = Prodigy.Server.Service.DowJones.roster() |> Enum.map(&elem(&1, 1))

    for banned <- ["GENERAL MOTORS", "INTL BUSINESS MACHINES", "IBM", "APPLE", "MICROSOFT"] do
      refute Enum.any?(names, &String.contains?(&1, banned)),
             "#{banned} is a real company; this roster is meant to be invented"
    end
  end
end
