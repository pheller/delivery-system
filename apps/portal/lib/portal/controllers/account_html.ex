defmodule Prodigy.Portal.AccountHTML do
  use Prodigy.Portal, :html

  def show(assigns) do
    ~H"""
    <h2>Hello, {@current_user.username}</h2>
    """
  end
end
