defmodule Prodigy.Portal.EnrollmentController do
  use Prodigy.Portal, :controller

  def new(conn, _params) do
    render(conn, :new)
  end
end
