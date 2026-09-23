# Copyright 2026, Phillip Heller
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

defmodule Prodigy.Server.RouterSandboxTest do
  @moduledoc """
  The sandbox wrap lives at the router's dispatch seam, so these drive
  `Router.handle_call/3` directly rather than a service module - the thing
  under test is the dispatch, not any one handler.
  """
  use Prodigy.Server.RepoCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Server.Context
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router

  # Profile write: one TAC set to `value` for `user_id`. Dest 0x00D203 routes
  # to the Profile service, which is not on the bypass list.
  defp write_packet(user_id, tac, value) do
    entry = <<tac::16-big, byte_size(value), value::binary>>

    %Fm0{
      src: 0x0,
      dest: 0x00D203,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x13, 0x04, 0x1, user_id::binary-size(7), 0::40, 1::16-big, entry::binary>>
    }
  end

  defp dispatch(user, packet) do
    state = %Router.State{context: %Context{user: user}}
    {:reply, reply, _state} = Router.handle_call({:handle_packet, packet}, nil, state)
    reply
  end

  defp create_user!(id, attrs) do
    household_id = String.slice(id, 0, 6)
    Repo.insert!(%Household{id: household_id, enabled_date: Date.utc_today(), profile: %{}})

    Repo.insert!(
      struct(
        %User{id: id, household_id: household_id, password: "SECRET", profile: %{}},
        attrs
      )
    )
  end

  defp reload_profile(id), do: Repo.get!(User, id).profile

  defp status_of(response) do
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    status
  end

  describe "sandboxed sessions" do
    test "a profile write is acknowledged but does not persist" do
      user = create_user!("SBX001A", sandbox: true)
      # 0x015E is the user's last name - :ascii, user-scoped, writable.
      packet = write_packet("SBX001A", 0x015E, "NEWNAME")

      assert {:ok, _response} = dispatch(user, packet)

      refute reload_profile("SBX001A")["015E"] == "NEWNAME"
    end

    test "the same write DOES persist for a non-sandboxed user" do
      user = create_user!("SBX002A", sandbox: false)
      packet = write_packet("SBX002A", 0x015E, "NEWNAME")

      assert {:ok, _response} = dispatch(user, packet)

      assert reload_profile("SBX002A")["015E"] == "NEWNAME"
    end

    test "the client gets the same status either way - it cannot tell" do
      sandboxed = create_user!("SBX003A", sandbox: true)
      normal = create_user!("SBX004A", sandbox: false)

      {:ok, sandboxed_response} = dispatch(sandboxed, write_packet("SBX003A", 0x015E, "SAME"))
      {:ok, normal_response} = dispatch(normal, write_packet("SBX004A", 0x015E, "SAME"))

      # The payloads echo their own user ids, so compare the status the client
      # actually branches on rather than the whole frame.
      assert status_of(sandboxed_response) == status_of(normal_response)
    end
  end

  # Everything above runs inside Ecto.Adapters.SQL.Sandbox, which wraps each
  # test in a transaction. That masks the difference between a top-level and a
  # nested transaction - and that difference is exactly what broke DEMO99A's
  # logon once already: `mode: :savepoint` returns {:error, :rollback} and
  # discards the value handed to Repo.rollback/1, so the handler's response was
  # lost and dispatch/3 raised MatchError. The suite stayed green because under
  # the sandbox there is always an enclosing transaction.
  #
  # unboxed_run/2 steps outside the sandbox, so these run against the real
  # database with no transaction wrapped around them - the production shape.
  # Writes here are NOT rolled back for us, hence the explicit cleanup.
  describe "outside the test sandbox (production transaction shape)" do
    @unboxed_sandboxed "UNBX01A"
    @unboxed_normal "UNBX02A"

    setup do
      on_exit(fn -> Sandbox.unboxed_run(Repo, &purge_unboxed/0) end)
      Sandbox.unboxed_run(Repo, &purge_unboxed/0)
      :ok
    end

    test "a sandboxed dispatch returns the handler's response, not {:error, :rollback}" do
      Sandbox.unboxed_run(Repo, fn ->
        user = create_user!(@unboxed_sandboxed, sandbox: true)

        # The assertion that matters: dispatch/3 must be able to destructure
        # what Repo.transaction returned. Under `mode: :savepoint` this raises.
        result = dispatch(user, write_packet(@unboxed_sandboxed, 0x015E, "NEWNAME"))

        assert {:ok, response} = result
        assert is_binary(response)

        # And with no enclosing transaction to hide behind, the rollback is
        # doing the real work: the write is genuinely gone from the database.
        refute reload_profile(@unboxed_sandboxed)["015E"] == "NEWNAME"
      end)
    end

    test "a non-sandboxed dispatch still persists when nothing wraps it" do
      Sandbox.unboxed_run(Repo, fn ->
        user = create_user!(@unboxed_normal, sandbox: false)

        assert {:ok, _response} = dispatch(user, write_packet(@unboxed_normal, 0x015E, "NEWNAME"))

        assert reload_profile(@unboxed_normal)["015E"] == "NEWNAME"
      end)
    end
  end

  defp purge_unboxed do
    for id <- ["UNBX01A", "UNBX02A"] do
      Repo.delete_all(from u in User, where: u.id == ^id)
      Repo.delete_all(from h in Household, where: h.id == ^String.slice(id, 0, 6))
    end
  end

  describe "the sandboxed? predicate" do
    test "true only for a user carrying the flag" do
      assert Router.sandboxed?(%Context{user: %User{id: "SBX9", sandbox: true}})
      refute Router.sandboxed?(%Context{user: %User{id: "SBX9", sandbox: false}})
    end

    test "a nil user - every packet before Logon runs - is not sandboxed" do
      refute Router.sandboxed?(%Context{user: nil})
    end
  end

  describe "bypass list" do
    test "session lifecycle and telemetry bypass; everything else is wrapped" do
      for service <- [
            Prodigy.Server.Service.Logon,
            Prodigy.Server.Service.Logoff,
            Prodigy.Server.Service.DataCollection
          ] do
        assert Router.sandbox_bypass?(service), "#{inspect(service)} should bypass the sandbox"
      end

      for service <- [
            Prodigy.Server.Service.Profile,
            Prodigy.Server.Service.Messaging,
            Prodigy.Server.Service.BulletinBoards,
            Prodigy.Server.Service.AddressBook,
            Prodigy.Server.Service.DowJones,
            Prodigy.Server.Service.Enrollment,
            Prodigy.Server.Service.Tocs
          ] do
        refute Router.sandbox_bypass?(service),
               "#{inspect(service)} must be wrapped - a new service defaults to sandboxed"
      end
    end
  end
end
