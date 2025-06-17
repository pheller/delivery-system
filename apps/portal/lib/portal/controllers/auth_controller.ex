defmodule Prodigy.Portal.AuthController do
  use Prodigy.Portal, :controller

  alias Prodigy.Portal.UserManager

  plug Ueberauth

  def request(conn, _params) do
    # render(conn, "request.html", callback_url: Helpers.callback_url(conn))
    conn
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    email = auth.info.email

    case UserManager.get_or_create(email) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Successfully authenticated.")
        |> put_session(:current_user, user)
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: "/")
    end
  end

  def callback(conn, _) do
    error = "Unexpected auth response"

    IO.puts(error)

    conn
    |> put_flash(:error, error)
    |> redirect(to: "/")
  end
end
