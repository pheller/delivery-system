defmodule Prodigy.Portal.RegistrationController do
  use Prodigy.Portal, :controller

  import Phoenix.Component

  alias Prodigy.Core.Data.Portal.User, as: PortalUser
  alias Prodigy.Portal.UserManager

  require Logger

  def new(conn, _) do
    form =
      %PortalUser{}
      |> UserManager.change_user()
      |> to_form()

    maybe_user = Guardian.Plug.current_resource(conn)

    if maybe_user do
      redirect(conn, to: ~p"/account")
    else
      render(conn, :new, form: form)
    end
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    with nil <- UserManager.get_user_by(%{username: username}),
         {:ok, _user} <- UserManager.create_user(%{username: username, password: password}) do
        Logger.info("user created successfully")

        conn
        |> put_flash(:info, "User created successfully")
        |> redirect(to: ~p"/login")

    else
      error ->
        Logger.info("user create failed")

        # TODO don't show this to user
        conn
        |> put_flash(:error, error)
        |> render(:new)
    end
  end

end
