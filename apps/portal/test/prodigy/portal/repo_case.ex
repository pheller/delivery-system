# Copyright 2023, Phillip Heller
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

defmodule Prodigy.Portal.RepoCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      @endpoint Prodigy.Portal.Endpoint

      use Prodigy.Portal, :verified_routes

      alias Prodigy.Core.Data.Repo

      import Ecto
      import Ecto.Query
      import Prodigy.Portal.RepoCase
      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup tags do
    :ok = Sandbox.checkout(Prodigy.Core.Data.Repo)

    unless tags[:async] do
      Sandbox.mode(Prodigy.Core.Data.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
