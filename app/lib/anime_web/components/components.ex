defmodule AnimeWeb.Components do
  use AnimeWeb, :html
  attr :form, :any, required: true
  attr :name, :atom, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :autocomplete, :string, default: "off"

  def field(assigns) do
    assigns = assign(assigns, :field, assigns.form[assigns.name])

    ~H"""
    <label class="field" for={@field.id}>
      <span>{@label}</span>
      <input
        id={@field.id}
        name={@field.name}
        value={if @type == "password", do: nil, else: @field.value}
        type={@type}
        autocomplete={@autocomplete}
        required
        aria-invalid={if @field.errors != [], do: "true", else: "false"}
      />
      <span :for={{msg, opts} <- @field.errors} class="field-error">{Gettext.dgettext(
        AnimeWeb.Gettext,
        "errors",
        msg,
        opts
      )}</span>
    </label>
    """
  end
end
