defmodule Prodigy.Portal.SessionController do
  use Prodigy.Portal, :controller

  alias Prodigy.Core.Data.Portal.User, as: PortalUser
  alias Prodigy.Portal.{UserManager, UserManager.Guardian}

  def new(conn, _) do
    changeset = UserManager.change_user(%PortalUser{})
    maybe_user = Guardian.Plug.current_resource(conn)

    if maybe_user do
      redirect(conn, to: "/protected")
    else
      # , action: Routes.session_path(conn, :login))
      render(conn, "new.html", changeset: changeset)
    end
  end

  def login(conn, %{"user" => %{"username" => username, "password" => password}}) do
    UserManager.authenticate_user(username, password)
    |> login_reply(conn)
  end

  def logout(conn, _) do
    conn
    # This module's full name is Auth.UserManager.Guardian.Plug,
    |> Guardian.Plug.sign_out()
    # and the arguments specified in the Guardian.Plug.sign_out()
    |> redirect(to: "/login")
  end

  # docs are not applicable here

  defp login_reply({:ok, user}, conn) do
    conn
    |> put_flash(:info, "Welcome back!")
    # This module's full name is Auth.UserManager.Guardian.Plug,
    |> Guardian.Plug.sign_in(user)
    # and the arguments specified in the Guardian.Plug.sign_in()
    |> redirect(to: "/protected")
  end

  # docs are not applicable here.

  defp login_reply({:error, reason}, conn) do
    conn
    |> put_flash(:error, to_string(reason))
    |> new(%{})
  end
end
