# Copyright 2022-2026, Phillip Heller and Ralph Richard Cook
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

defmodule Prodigy.Server.Router do
  @moduledoc """
  The Router implements the service invocation function and stores context data.

  An instance of the Router is created for each active connection.

  The Router is responsible for:
  * Storing an instance of `Prodigy.Server.Context`
  * receiving packets from `Prodigy.Server.Protocol.Dia`
  * invoking the appropriate Service (that implements `Prodigy.Server.Service`) and passing to it the packet itself and
    the context
  * Storing the updated Context as received from the Service
  * Returning any response received from the service to the reception system (note, DIA vs TOCS)
  """

  require Logger
  use GenServer
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.User
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  alias Prodigy.Server.Service.{
    AddressBook,
    Ads,
    BulletinBoards,
    Cmc,
    DataCollection,
    DowJones,
    EaasySabre,
    Enrollment,
    Logoff,
    Logon,
    Messaging,
    Profile,
    Tocs
  }

  defmodule State do
    defstruct context: %Context{}
  end

  def handle_packet(pid, %Fm0{} = packet), do: GenServer.call(pid, {:handle_packet, packet})

  @impl GenServer
  def init(opts) do
    Logger.debug("router started")
    Process.flag(:trap_exit, true)

    peer_info =
      case opts do
        %{peer_info: pi} when is_map(pi) -> pi
        _ -> %{}
      end

    transport_type =
      case opts do
        %{transport_type: t} -> t
        _ -> nil
      end

    context = %Context{
      auth_timeout: Context.set_auth_timer(),
      transport: transport_type,
      source_address: Map.get(peer_info, :address),
      source_port: Map.get(peer_info, :port)
    }

    {:ok, %State{context: context}}
  end

  defmodule Default do
    @moduledoc "A default implementation of Prodigy.Server.Service to handle packets to unknown destinations"
    @behaviour Prodigy.Server.Service

    def handle(%Fm0{dest: dest} = packet, state) do
      Logger.error("FM0 packet to unknown destination #{inspect(dest, base: :hex)}")
      Logger.debug("#{inspect(packet, base: :hex, limit: :infinity)}")
      {:ok, state, <<>>}
    end
  end

  @doc """
  Dispatch packets to the relevant service module.

  The service module is selected by the following:
  * DIA destination ID
  * When necessary, the first byte of the DIA packet payload

  The entire deserialized DIA Fm0 packet (`Prodigy.Server.Protocol.Dia.Packet.Fm0`) and the `Prodigy.Server.Context` is
  passed to the service.  The service returns:
  * A status atom (:ok, :error, or :disconnect)
  * The `Prodigy.Server.Context` struct, updated as appropriate
  * Optionally, A binary response payload

  The router will update the stored `Prodigy.Server.Context` with the value returned, and the binary response payload
  will be returned to `Prodigy.Server.Protocol.Dia`, then to `Prodigy.Server.Protocol.Tcs` where it will ultimately be
  chunked, encapsulated, and sent to the Reception System.
  """
  # credo:disable-for-lines:2 Credo.Check.Refactor.CyclomaticComplexity
  @impl GenServer
  def handle_call({:handle_packet, %Fm0{dest: dest, payload: payload} = packet}, _from, state) do
    service =
      case dest do
        0x000200 ->
          Tocs

        0x002200 ->
          Logon

        0x002201 ->
          Enrollment

        0x00D200 ->
          case payload do
            <<0x01, _rest::binary>> -> Messaging
            <<0x02, _rest::binary>> -> Ads
            <<0x03, _rest::binary>> -> BulletinBoards
            <<0x04, _rest::binary>> -> DataCollection
            # sends 0xF on entry and exit; Mailing List sends 06
            <<0x0D, _rest::binary>> -> AddressBook
            # MSZX0BIP message-count query (compose OPTIONS -> Count)
            <<0x11, _rest::binary>> -> Messaging
          end

        0x00D201 ->
          Logoff

        # This is for subsequent logons, so no disconnect, but set the auth_timeout
        0x00D202 ->
          Logoff

        0x00D203 ->
          Profile

        0x020200 ->
          Cmc

        # HFH host-index channel. DJ company/fund name search sends HI400010
        # queries here; quote-track also uses it (not yet modeled).
        0x040210 ->
          DowJones

        # 0x060201 -> Banking

        0x063201 ->
          EaasySabre

        0x067201 ->
          DowJones

        # this is the made up destination for the dow jones symbol to name resolve function
        0x009900 ->
          DowJones

        _ ->
          Default
      end

    case dispatch(service, packet, state.context) do
      {:ok, %Context{} = context} ->
        {:reply, {:ok}, %{state | context: context}}

      {:ok, %Context{} = context, response} ->
        {:reply, {:ok, response}, %{state | context: context}}

      {:error, %Context{} = context, response} ->
        {:reply, {:ok, response}, %{state | context: context}}

      # but want to exit at the end of this
      {:disconnect, %Context{}, response} ->
        {:reply, {:ok, response}, %Context{}}
    end
  end

  # A sandboxed session runs every service call inside a transaction that is
  # always rolled back. The handler executes for real - it builds the same
  # response the client would get from a genuine write, and sees its own writes
  # within the request - and then nothing persists.
  #
  # This sits at the single dispatch seam rather than in the handlers, so a
  # service revived later is sandboxed whether or not anyone remembered it
  # existed. That is the point: `sandbox_bypass?/1` below defaults to false.
  #
  # Ecto joins a nested `Repo.transaction` to this outer one, so a service's own
  # transactions commit into it and are discarded with it. That holds only
  # because no service calls `Repo.rollback/1` - an inner rollback would unwind
  # this transaction and skip the rest of the handler, taking a different path
  # under the wrap than without it. See the guard test in router_sandbox_test.
  defp dispatch(service, packet, context) do
    if sandboxed?(context) and not sandbox_bypass?(service) do
      {:error, {:sandboxed, result}} =
        # Default mode, deliberately. `mode: :savepoint` DISCARDS the value
        # passed to Repo.rollback/1 - it returns {:error, :rollback} - which
        # loses the handler's response and leaves the client with nothing.
        Repo.transaction(fn ->
          Repo.rollback({:sandboxed, service.handle(packet, context)})
        end)

      result
    else
      service.handle(packet, context)
    end
  end

  @doc false
  # Public alongside sandbox_bypass?/1 so the policy is asserted directly.
  def sandboxed?(%Context{user: %User{sandbox: true}}), do: true
  def sandboxed?(_context), do: false

  # Services that must persist even for a sandboxed session: the session
  # lifecycle itself (Logon writes the session row and the last-logon stamp,
  # Logoff closes it) and usage telemetry. Everything else is wrapped - a new
  # service is sandboxed by default, and exempting one is a deliberate act here.
  @doc false
  # Public so the policy itself can be asserted in a test rather than
  # re-implemented there.
  def sandbox_bypass?(Logon), do: true
  def sandbox_bypass?(Logoff), do: true
  def sandbox_bypass?(DataCollection), do: true
  def sandbox_bypass?(_service), do: false

  @impl GenServer
  def terminate(reason, %{context: %Context{user: user}} = _state) do
    # If the router is terminated with a connection still active, log the user off
    Logoff.handle_abnormal(user)
    Logger.debug("Router shutting down: #{inspect(reason)}")
    :normal
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("router state: #{inspect(state)}")
    Logger.debug("Router shutting down: #{inspect(reason)}")
    :normal
  end

  @impl true
  def handle_info(:auth_timeout, %{context: %Context{user: nil}} = state) do
    Logger.warning("authentication timeout")
    {:stop, :normal, state}
  end

  def handle_info(:auth_timeout, %{context: %Context{user: _user}} = state) do
    # User is logged in, ignore timeout
    {:noreply, state}
  end

  @impl GenServer
  # Stop on any trapped exit. Router has no sub-processes whose deaths
  # would be tolerable ignores, so the right move is always to tear the
  # connection down. This also lets admin force-disconnect work: the LiveView
  # sends Process.exit(router, :shutdown), Router stops, DIA gets the
  # EXIT via its downward link and stops, TCS gets the EXIT from DIA
  # and stops, the WebSock handler (or Ranch socket) closes the client.
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end
end
