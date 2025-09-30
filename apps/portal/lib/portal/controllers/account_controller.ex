defmodule Prodigy.Portal.AccountController do
  use Prodigy.Portal, :controller

  def show(conn, _params) do
    render(conn, :show)
  end
end
