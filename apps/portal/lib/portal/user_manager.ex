defmodule Prodigy.Portal.UserManager do
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Portal.User, as: PortalUser

  alias Pbkdf2

  import Ecto.Query

  def list_users do
    Repo.all(PortalUser)
  end

  def get_user!(id), do: Repo.get!(PortalUser, id)

  def create_user(attrs \\ %{}) do
    %PortalUser{}
    |> PortalUser.changeset(attrs)
    |> Repo.insert()
  end

  def get_or_create(%{} = attrs) do
    case Repo.get_by(PortalUser, attrs) do
      nil -> create_user(attrs)
      user -> {:ok, user}
    end
  end

  def update_user(%PortalUser{} = user, attrs) do
    user
    |> PortalUser.changeset(attrs)
    |> Repo.update()
  end

  def delete_user(%PortalUser{} = user) do
    Repo.delete(user)
  end

  def change_user(%PortalUser{} = user) do
    PortalUser.changeset(user, %{})
  end

  def authenticate_user(username, plain_text_password) do
    query = from(u in PortalUser, where: u.username == ^username)

    case Repo.one(query) do
      nil ->
        Pbkdf2.no_user_verify()
        {:error, :invalid_credentials}

      user ->
        if Pbkdf2.verify_pass(plain_text_password, user.password) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end
end
