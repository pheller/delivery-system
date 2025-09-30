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

defmodule Prodigy.Core.Data.Portal.User do
  use Ecto.Schema

  import Ecto.Changeset

  alias Ecto.Changeset

  @moduledoc """
  Schema specific to individual users and related change functions
  """

  alias Pbkdf2

  schema "portal_user" do
    field :username, :string
    field :password, :string, virtual: true
    field :password_hashed, :string

    # :github requires :provider_uid, :password requires :password, :sandbox temporarily no requirements
    field :provider, Ecto.Enum, values: [:github, :password, :sandbox]
    field :provider_uid, :integer

    timestamps()
  end

  def changeset(user, %{provider: :github} = attrs) do
    user
    |> cast(attrs, [:provider, :provider_uid, :username])
    |> validate_required([:provider, :provider_uid, :username])
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> change(provider: :password)
    |> put_password_hash()
  end

  defp put_password_hash(%Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> change(password_hashed: Pbkdf2.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp put_password_hash(changeset), do: changeset

end
