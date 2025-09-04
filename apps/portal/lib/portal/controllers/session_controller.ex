defmodule Prodigy.Portal.SessionController do
  use Prodigy.Portal, :controller

  alias Prodigy.Core.Data.Portal.User, as: PortalUser
  alias Prodigy.Portal.UserManager
  alias Prodigy.Portal.UserManager.Guardian
  alias Prodigy.Portal.UserManager.Guardian.Plug

  def new(conn, _) do
    changeset = UserManager.change_user(%PortalUser{})
    maybe_user = Guardian.Plug.current_resource(conn)

    if maybe_user do
      redirect(conn, to: "/protected")
    else
      render(conn, "new.html", changeset: changeset)
    end
  end

  def login(conn, %{"user" => %{"username" => username, "password" => password}}) do
    UserManager.authenticate_user(username, password)
    |> login_reply(conn)
  end

  def logout(conn, _) do
    conn
    |> Plug.sign_out()
    |> put_session(:user_id, nil)
    |> redirect(to: "/login")
  end

  defp login_reply({:ok, user}, conn) do
    conn
    |> put_flash(:info, "Welcome back!")
    |> Plug.sign_in(user)
    |> put_session(:user_id, user.id)
    |> redirect(to: "/protected")
  end

  defp login_reply({:error, reason}, conn) do
    conn
    |> put_flash(:error, to_string(reason))
    |> new(%{})
  end
end
