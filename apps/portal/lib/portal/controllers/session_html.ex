defmodule Prodigy.Portal.SessionHTML do
  use Prodigy.Portal, :html

  def new(assigns) do
    ~H"""
    <div class="max-w-md m-20">
      <header class="font-bold">Login to an existing account</header>

      <.simple_form for={@form} action={~p"/login"}>
        <.input field={@form[:username]} label="Username" />
        <.input field={@form[:password]} label="Password" />
        <:actions>
          <.button>Login</.button>
        </:actions>
      </.simple_form>

      <div class="my-16">
        <span>Not yet set up?</span>
        <.button_link href="/register">Create new account instead</.button_link>
      </div>
    </div>
    """
  end
end
