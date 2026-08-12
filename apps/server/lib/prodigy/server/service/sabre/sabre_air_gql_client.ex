# Copyright 2022-2025, Ralph Richard Cook
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

defmodule Prodigy.Server.Service.Sabre.SabreAirGqlClient do
  @moduledoc """
  GraphQL client implementation for Sabre Air requests.

  This module implements the `Prodigy.Server.Service.Sabre.SabreAirClient` behaviour,
  handling flight queries by sending GraphQL requests to a configured endpoint and
  parsing the responses.

  ## Configuration

  The GraphQL endpoint URL can be configured via:

      config :server, :sabre_graphql_url, "http://your-api-endpoint/api/graphql"

  If not configured, defaults to `http://localhost:4004/api/graphql`.
  """

  alias Prodigy.Server.Service.EaasySabre
  alias Prodigy.Server.Service.Sabre.SabreAirMapper

  require Logger

  @url "http://localhost:4004/api/graphql"

  @behaviour Prodigy.Server.Service.Sabre.SabreAirClient

  @doc """
  Handles a Sabre Air request by querying the GraphQL flight API.

  Builds a GraphQL query from the request map, sends it to the configured
  endpoint, and parses the response into a list of flight maps.
  """
  def handle_request(sabre_map) do
    # Implementation of request handling

    # A string will be posted to the GraphQL endpoint and a response received
    post_body = build_request(sabre_map)

    Logger.debug("Sending GraphQL request: #{post_body}")
    url = Application.get_env(:server, :sabre_graphql_url, @url)

    response =
      Req.post(url,
        body: post_body,
        headers: %{"Content-Type" => "text/plain"}
      )

    Logger.debug("Received GraphQL response: #{inspect(response, limit: 50)}")
    parse_response(response)
  end

  defp parse_response(response) do
    # Parse the GraphQL response body and extract flight information
    case response do
      {:ok, %Req.Response{status: 200, body: body}} ->
        try do
          body |> Map.get("data") |> Map.get("itineraries") |> es_map()
        rescue
          e ->
            Logger.warning("Failed to parse GraphQL response body: #{inspect(e)}")
            []
        end

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("GraphQL request failed with status: #{status}")
        []

      {:error, reason} ->
        Logger.error("GraphQL request error: #{inspect(reason)}")
        []
    end
  end

  defp build_request(sabre_map) do
    # Query the itinerary assembler (nonstop + through + connection) so O&D pairs
    # with no direct flight (e.g. SEA->BOS) still return results. The old
    # nonstop-only `flights` query returned nothing for those.
    origin_text = "origin: \"#{sabre_map.departure}\", "
    dest_text = "dest: \"#{sabre_map.arrival}\", "
    date_text = "date: \"#{sabre_map.date}\", "

    # Honor a requested "no earlier than" departure time when the user gave one.
    after_text =
      if Map.has_key?(sabre_map, :time) and sabre_map.time != nil do
        "departureAfter: \"#{sabre_map.time}\", "
      else
        ""
      end

    # Fetch several pages' worth of itineraries so the NEXT function has results
    # to page through (the results page shows ~3-6 per page depending on how many
    # are two-row connections). The renderer/eaasy_sabre pages through this set.
    """
    query {
      itineraries(
        #{origin_text}
        #{dest_text}
        #{date_text}
        #{after_text}
        limit: #{EaasySabre.max_flights() * 8}) {
          kind
          stops
          origin
          dest
          date
          departureTime
          arrivalTime
          legs {
            carrier
            flightNumber
            origin
            dest
            equip
            departureTime
            arrivalTime
          }
          availability {
            class
            seats
          }
          fares {
            class
            fare
          }
      }
    }
    """
  end

  # Converts the itineraries GraphQL response into the flight-row maps the
  # eaasy_sabre renderer expects.
  defp es_map(itineraries) when is_list(itineraries) do
    itineraries
    |> Enum.map(&es_one_itin_map/1)
    |> Enum.with_index()
    |> Enum.map(fn {itin, idx} -> Map.put(itin, :index, idx) end)
  end

  @all_classes ["F", "Y", "B", "M", "H", "Q", "V", "K"]

  defp es_one_itin_map(itin) do
    legs = Map.get(itin, "legs", [])
    first = List.first(legs) || %{}
    kind = Map.get(itin, "kind")

    itin_depart = Time.from_iso8601!(Map.get(itin, "departureTime")) |> SabreAirMapper.time_to_sabre()
    itin_arrive = Time.from_iso8601!(Map.get(itin, "arrivalTime")) |> SabreAirMapper.time_to_sabre()

    header_date = Date.from_iso8601!(Map.get(itin, "date"))
    formatted_date = Calendar.strftime(header_date, "%3b %02d %02y") |> String.upcase()

    # Only offer booking classes that have seats; fall back to the full set when
    # the pseudo-inventory shows this itinerary sold out.
    available =
      itin
      |> Map.get("availability", [])
      |> Enum.filter(fn a -> (a["seats"] || 0) > 0 end)
      |> Enum.map(& &1["class"])

    booking_classes = if available == [], do: @all_classes, else: available

    # Display rows: a connection (change of planes) shows one row per segment; a
    # nonstop or a same-flight-number through service shows a single row (with the
    # stop count). The renderer puts the selection chevron on the first row only.
    rows =
      case kind do
        "connection" -> Enum.map(legs, &seg_row/1)
        _ -> [collapsed_row(itin, first, itin_depart, itin_arrive)]
      end

    %{
      # Top-level fields describe the whole itinerary (used by the booking pages).
      flight: seg_label(first),
      origin: Map.get(itin, "origin"),
      depart: itin_depart,
      dest: Map.get(itin, "dest"),
      arrive: itin_arrive,
      formatted_date: formatted_date,
      stops: Map.get(itin, "stops", 0),
      equip: Map.get(first, "equip") || "D9S",
      meal: "8",
      booking_classes: booking_classes,
      kind: kind,
      segments: legs,
      rows: rows
    }
  end

  # "AA" + "108" -> "AA  108" (flight number right-justified to 4).
  defp seg_label(leg),
    do: Map.get(leg, "carrier", "") <> " " <> String.pad_leading(Map.get(leg, "flightNumber", ""), 4, " ")

  # One display row for a single flown segment (always shown as nonstop).
  defp seg_row(leg) do
    %{
      flight: seg_label(leg),
      origin: leg["origin"],
      depart: Time.from_iso8601!(leg["departureTime"]) |> SabreAirMapper.time_to_sabre(),
      dest: leg["dest"],
      arrive: Time.from_iso8601!(leg["arrivalTime"]) |> SabreAirMapper.time_to_sabre(),
      stops: 0,
      equip: leg["equip"] || "D9S",
      meal: "8"
    }
  end

  # One collapsed row for a nonstop or same-flight-number through itinerary: the
  # single flight number over the whole O&D, carrying the itinerary's stop count.
  defp collapsed_row(itin, first, depart, arrive) do
    %{
      flight: seg_label(first),
      origin: Map.get(itin, "origin"),
      depart: depart,
      dest: Map.get(itin, "dest"),
      arrive: arrive,
      stops: Map.get(itin, "stops", 0),
      equip: Map.get(first, "equip") || "D9S",
      meal: "8"
    }
  end
end
