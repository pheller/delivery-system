defmodule Prodigy.Portal.RegistrationHTML do
  use Prodigy.Portal, :html

  def new(assigns) do
    ~H"""
    <div class="max-w-md m-20">
      <header class="font-bold">Register a new account</header>

    <.simple_form for={@form} action={~p"/register"}>
        <.input field={@form[:username]} label="Username" />
        <.input field={@form[:password]} label="Password" />
        <span class="italic">don't lose this!</span>
        <:actions>
          <.button>Create Account</.button>
        </:actions>
      </.simple_form>

      <div class="my-16">
        <span>Already have an account?</span>
        <.button_link href="/login">Login instead</.button_link>
      </div>
    </div>
    """
  end
end
