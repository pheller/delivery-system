defmodule Prodigy.Portal.PageController do
  use Prodigy.Portal, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def project(conn, _params) do
    render(conn, :project, layout: false)
  end

  def news(conn, _params) do
    render(conn, :news, layout: false)
  end

  def get_started(conn, _params) do
    render(conn, :get_started, layout: false)
  end

  def login(conn, _params) do
    render(conn, :login, layout: false)
  end

  def account(conn, _params) do
    render(conn, :account, layout: false)
  end
end
