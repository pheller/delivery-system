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

defmodule Prodigy.Portal.Admin.UsersSandboxTest do
  use Prodigy.Portal.DataCase, async: false

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Enroller, User}
  alias Prodigy.Portal.Admin.Users, as: Admin

  defp subscriber!(id) do
    {:ok, {_household, user}} = Enroller.create_subscriber(id, "SECRET", concurrency_limit: 1)
    user
  end

  describe "set_sandbox/2" do
    test "turns the flag on and off" do
      user = subscriber!("SBXA01")
      refute user.sandbox

      assert {:ok, on} = Admin.set_sandbox(user, true)
      assert on.sandbox
      assert Repo.get!(User, user.id).sandbox

      assert {:ok, off} = Admin.set_sandbox(on, false)
      refute off.sandbox
      refute Repo.get!(User, user.id).sandbox
    end

    test "is idempotent" do
      user = subscriber!("SBXA02")

      assert {:ok, _} = Admin.set_sandbox(user, true)
      assert {:ok, still_on} = Admin.set_sandbox(Repo.get!(User, user.id), true)

      assert still_on.sandbox
    end

    test "leaves every other field alone" do
      user = subscriber!("SBXA03")

      assert {:ok, updated} = Admin.set_sandbox(user, true)

      assert updated.concurrency_limit == user.concurrency_limit
      assert updated.password == user.password
      assert updated.date_enrolled == user.date_enrolled
      assert updated.profile == user.profile
      assert updated.date_deleted == user.date_deleted
    end

    test "sandboxing does not delete or disable the account" do
      # Containment, not a ban: the user still logs on and the session works.
      # That is the whole point - they get no signal.
      user = subscriber!("SBXA04")

      assert {:ok, updated} = Admin.set_sandbox(user, true)

      assert is_nil(updated.date_deleted)
    end
  end

  describe "Enroller" do
    test "creates non-sandboxed by default" do
      refute subscriber!("SBXA05").sandbox
    end

    test "honours the :sandbox option" do
      {:ok, {_household, user}} =
        Enroller.create_subscriber("SBXA06", "SECRET", concurrency_limit: 0, sandbox: true)

      assert user.sandbox
      assert Repo.get!(User, user.id).sandbox
    end
  end
end
