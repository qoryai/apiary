defmodule ApiaryWeb.CoreComponents do
  @moduledoc """
  Core UI components of the Qory console.

  daisyUI 5 components with Qory's overrides and tokens from
  `assets/css/app.css`: `border-line`, `text-muted`, `text-faint`, `bg-code`,
  the `*-soft` pairs, `shadow-xs`, `shadow-pop`, `shadow-modal`, and daisyUI's
  `rounded-selector`, `rounded-field`, `rounded-box`.

  Icons come from [Heroicons](https://heroicons.com), see `icon/1`.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText

  alias ApiaryWeb.Format
  alias Phoenix.LiveView.JS

  # Qory's words and the standard term they show on hover.
  ## Brand

  @doc """
  The mark: one cell of comb with a tail, a hexagon that reads as a Q. The body
  takes `primary` and the tail `base-content`, so it is right in both themes.
  """
  attr :class, :any, default: "size-[22px]"

  def logo_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 32 32" aria-hidden="true" class={["flex-none", @class]}>
      <path
        fill="var(--color-primary)"
        fill-rule="evenodd"
        d="M16 2.2 27.95 9.1v13.8L16 29.8 4.05 22.9V9.1L16 2.2Zm0 7.6-5.37 3.1v6.2L16 22.2l5.37-3.1v-6.2L16 9.8Z"
      />
      <path fill="var(--color-base-content)" d="m17.35 17.1 2.6-1.5 6.2 10.74-2.6 1.5z" />
    </svg>
    """
  end

  @doc """
  The mark with the wordmark "Qory Apiary", as a link to `/`. `xs` is the
  sidebar foot (18 px mark, grey wordmark: a signature, not a heading), `sm`
  the `/users/organisations` top bar and the auth header strip (22 px mark),
  `lg` the auth panel (28 px mark).
  """
  attr :class, :any, default: nil
  attr :href, :string, default: "/"
  attr :size, :string, default: "sm", values: ~w(xs sm lg)

  def brand(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "inline-flex items-center gap-2 rounded-field",
        if(@size == "xs",
          do: "text-muted transition-colors hover:text-base-content",
          else: "text-base-content"
        ),
        @class
      ]}
    >
      <.logo_mark class={
        case @size do
          "xs" -> "size-[18px]"
          "sm" -> "size-[22px]"
          "lg" -> "size-7"
        end
      } />
      <span class={[
        "whitespace-nowrap tracking-[-0.03em]",
        case @size do
          "xs" -> "text-[13px]/[18px] font-medium"
          "sm" -> "text-base/5 font-semibold"
          "lg" -> "text-[19px]/6 font-semibold"
        end
      ]}>
        Qory Apiary
      </span>
    </a>
    """
  end

  ## Vocabulary

  @doc """
  Renders one of Qory's words with its standard term on hover and focus.

      <.term word="wall" standard="The enclosure the agent runs in." />

  Not a way to show a word such as apiary or hive: a page says organisation and workspace
  through Gettext (`docs/lingo.md`).
  """
  attr :word, :string, required: true
  attr :standard, :string, required: true, doc: "the standard term, or what the word means"
  attr :class, :any, default: nil

  def term(assigns) do
    ~H"""
    <abbr
      class={["term tooltip", @class]}
      tabindex="0"
      data-tip={@standard}
      aria-label={"#{@word} (#{@standard})"}
    >{@word}</abbr>
    """
  end

  ## Feedback

  @doc """
  Renders a flash notice as a toast. The toast stays neutral; only the icon
  carries colour. A message of two sentences shows the first as the title and
  the rest as a muted second line.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash id="client-error" kind={:error} title="Connection lost." spinner hidden>
        Reconnecting.
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :spinner, :boolean, default: false, doc: "a spinner in place of the dismiss button"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)
    flash_msg = Phoenix.Flash.get(assigns.flash, assigns.kind)

    {title, body} =
      cond do
        assigns.title -> {assigns.title, nil}
        is_binary(flash_msg) -> split_sentences(flash_msg)
        true -> {nil, nil}
      end

    assigns =
      assign(assigns,
        toast_title: title,
        toast_body: body,
        dismiss: JS.push("lv:clear-flash", value: %{key: assigns.kind}) |> hide("##{assigns.id}")
      )

    ~H"""
    <div
      :if={@toast_title}
      id={@id}
      role={if @kind == :info, do: "status", else: "alert"}
      phx-hook={@kind == :info && !@spinner && "Toast"}
      data-dismiss={@kind == :info && !@spinner && @dismiss}
      class="pointer-events-auto grid w-full grid-cols-[16px_1fr_auto] items-start gap-2.5 rounded-box bg-base-100 p-3 text-[13px]/[18px] shadow-pop sm:w-[360px]"
      {@rest}
    >
      <.icon
        :if={@kind == :info}
        name="hero-check-circle-micro"
        class="mt-px size-4 text-success"
      />
      <.icon
        :if={@kind == :error}
        name="hero-exclamation-triangle-micro"
        class="mt-px size-4 text-error"
      />
      <div class="min-w-0 break-words">
        <p class="font-medium">{@toast_title}</p>
        <p :if={@toast_body} class="text-muted">{@toast_body}</p>
        <p :if={@inner_block != []} class="text-muted">{render_slot(@inner_block)}</p>
      </div>
      <span :if={@spinner} class="loading loading-spinner mt-px size-3.5 text-faint" />
      <.tooltip :if={!@spinner} tip={gettext("Dismiss")} placement="left" class="-m-0.5">
        <button
          type="button"
          phx-click={@dismiss}
          class="grid size-5 cursor-pointer place-items-center rounded-selector text-faint transition-colors hover:bg-base-300 hover:text-base-content"
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </.tooltip>
    </div>
    """
  end

  # "build-01 is revoked. Machines using it fail." -> {"build-01 is revoked.", "Machines ..."}
  defp split_sentences(msg) do
    case String.split(msg, ~r/(?<=[.?])\s+(?=[A-Z])/, parts: 2) do
      [title, body] -> {title, body}
      [title] -> {title, nil}
    end
  end

  @doc """
  An inline notice: a soft fill, an icon, no close button. `:success` says a thing the
  reader waited for has happened.
  """
  attr :kind, :atom, default: :info, values: [:info, :warning, :error, :success]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div
      role={if @kind == :error, do: "alert", else: "note"}
      class={[
        "alert alert-soft",
        @kind == :info && "bg-info-soft text-info-soft-content",
        @kind == :warning && "bg-primary-soft text-primary-soft-content",
        @kind == :error && "bg-error-soft text-error-soft-content",
        @kind == :success && "bg-success-soft text-success-soft-content",
        @class
      ]}
    >
      <.icon
        name={
          case @kind do
            :info -> "hero-information-circle-micro"
            :warning -> "hero-exclamation-triangle-micro"
            :error -> "hero-exclamation-circle-micro"
            :success -> "hero-check-circle-micro"
          end
        }
        class="mt-px size-4"
      />
      <div class="min-w-0 [&_strong]:font-semibold">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  A tooltip around an icon-only control. Never holds essential information:
  the control's `aria-label` carries the same words.
  """
  attr :tip, :string, required: true
  attr :placement, :string, default: "top", values: ~w(top bottom left right)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span
      class={[
        "tooltip inline-flex",
        @placement == "bottom" && "tooltip-bottom",
        @placement == "left" && "tooltip-left",
        @placement == "right" && "tooltip-right",
        @class
      ]}
      data-tip={@tip}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  The in-place confirmation after a link is emailed: log in and register.
  """
  attr :on_back, :string, default: nil, doc: "the event of the ghost button back to the form"
  slot :inner_block, required: true

  def check_your_email(assigns) do
    ~H"""
    <div id="check-your-email" class="grid gap-4" role="status">
      <.hex_tile icon="hero-envelope" />
      <div class="grid gap-1.5">
        <h1
          class="text-2xl/8 font-semibold tracking-[-0.025em] outline-none sm:text-3xl/9"
          tabindex="-1"
          phx-mounted={JS.focus()}
        >
          {gettext("Check your email")}
        </h1>
        <p class="text-sm/5 text-muted">{render_slot(@inner_block)}</p>
      </div>
      <.button :if={@on_back} variant="ghost" size="md" class="btn-block" phx-click={@on_back}>
        {gettext("Use a different email")}
      </.button>
    </div>
    """
  end

  @doc """
  Development only: where sent mail goes. One faint line under the form.
  """
  def dev_mailbox_note(assigns) do
    ~H"""
    <p :if={local_mail_adapter?()} class="text-center text-[12.5px]/[18px] text-faint">
      <.rich text={
        rich_gettext("Dev: sent mail is in the %{mailbox}.",
          mailbox:
            {:href, "/dev/mailbox", gettext("mailbox"),
             "underline decoration-line-field underline-offset-[3px] hover:text-base-content"}
        )
      } />
    </p>
    """
  end

  defp local_mail_adapter? do
    Application.get_env(:apiary, :dev_routes, false) &&
      Application.get_env(:apiary, Apiary.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  ## Buttons

  @doc """
  Renders a button, or a link styled as one when `href`, `navigate` or `patch` is given.

  `loading_text` is the gerund shown with a spinner while the button's form
  submits or its click is in flight; the button keeps its width. A `link` button, a
  row's text action, takes none: its words stay while it is in flight.

  ## Examples

      <.button variant="primary" loading_text="Saving">Save</.button>
      <.button navigate={~p"/\#{@current_scope.organisation}/\#{@current_scope.workspace}"}>Back</.button>
      <.button variant="danger" phx-click="revoke" loading_text="Revoking">Revoke key</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any, default: nil

  attr :variant, :string,
    default: "default",
    values: ~w(primary default ghost danger danger-ghost link)

  attr :size, :string, default: "sm", values: ~w(xs sm md)
  attr :loading_text, :string, default: nil
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns = assign(assigns, :classes, button_classes(assigns))

    # `disabled` means nothing on a link: a disabled button with a path is a real
    # `<button disabled>`, so it is neither focusable nor announced as a link.
    if (rest[:href] || rest[:navigate] || rest[:patch]) && !rest[:disabled] do
      ~H"""
      <.link class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      assigns =
        if rest[:disabled],
          do:
            update(assigns, :rest, &Map.drop(&1, [:href, :navigate, :patch, :method, :download])),
          else: assigns

      ~H"""
      <button
        class={@classes}
        data-busy={@loading_text && @variant != "link" && ""}
        {@rest}
      >
        <%= if @loading_text && @variant != "link" do %>
          <span class="btn-label">{render_slot(@inner_block)}</span>
          <span class="btn-busy" aria-hidden="true">
            <span class="loading loading-spinner loading-xs" />{@loading_text}
          </span>
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </button>
      """
    end
  end

  defp button_classes(%{variant: "link"} = assigns) do
    [
      "cursor-pointer rounded-selector font-medium text-accent underline decoration-transparent",
      "underline-offset-[3px] transition-colors hover:decoration-current",
      assigns.class
    ]
  end

  defp button_classes(assigns) do
    [
      "btn",
      "btn-#{assigns.size}",
      case assigns.variant do
        "primary" -> "btn-primary"
        "default" -> nil
        "ghost" -> "btn-ghost"
        "danger" -> "btn-error"
        "danger-ghost" -> "btn-ghost btn-danger"
      end,
      assigns.class
    ]
  end

  @doc """
  A copy-to-clipboard button. Copies `text`, or the text content of the
  element `target` selects, via the CopyToClipboard hook. `icon_only` renders
  a square button with a tooltip.
  """
  attr :id, :string, required: true
  attr :text, :string, default: nil
  attr :target, :string, default: nil, doc: "a CSS selector whose text content is copied"
  attr :label, :string, default: nil, doc: "defaults to Copy"
  attr :icon_only, :boolean, default: false
  attr :placement, :string, default: "top"
  attr :class, :any, default: nil

  def copy_button(%{label: nil} = assigns),
    do: copy_button(assign(assigns, :label, gettext("Copy")))

  def copy_button(%{icon_only: true} = assigns) do
    ~H"""
    <.tooltip tip={@label} placement={@placement} class={@class}>
      <button
        id={@id}
        type="button"
        phx-hook="CopyToClipboard"
        data-copied-words={gettext("Copied")}
        data-copy={@text}
        data-copy-target={@target}
        class="copy-btn btn btn-ghost btn-xs btn-square"
        aria-label={@label}
      >
        <span class="copy-idle"><.icon name="hero-clipboard-document" class="size-4" /></span>
        <span class="copy-done"><.icon name="hero-check-micro" class="size-4" /></span>
        <span class="sr-only" aria-live="polite"></span>
      </button>
    </.tooltip>
    """
  end

  def copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook="CopyToClipboard"
      data-copied-words={gettext("Copied")}
      data-copy={@text}
      data-copy-target={@target}
      class={["copy-btn btn btn-ghost btn-xs btn-keep font-sans", @class]}
    >
      <span class="copy-idle">
        <.icon name="hero-clipboard-document" class="size-4" />{@label}
      </span>
      <span class="copy-done"><.icon name="hero-check-micro" class="size-4" />{gettext("Copied")}</span>
      <span class="sr-only" aria-live="polite"></span>
    </button>
    """
  end

  ## Forms

  @doc """
  Renders an input with label, hint and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument, which is used to
  retrieve the input name, id, and values. Otherwise all attributes may be
  passed explicitly. Fields carry no margin: the form's `grid gap-4` spaces them.

  ## Examples

      <.input field={@form[:email]} type="email" label="Email" />
      <.input field={@form[:level]} type="select" options={[Owner: "owner"]} />
      <.input field={@form[:kind]} type="radio" label="Create" options={[{"An organisation", "organisation"}]} />
      <.input field={@form[:slug]} type="text" label="Address" prefix="qory.example/acme/" />

  A `radio` input is a group: its label is the group's legend, and each of `options`, a
  `{label, value}`, one choice. A text input with a `prefix` shows it in mono before the
  value, as one field: the path a slug completes.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :optional, :boolean, default: false, doc: "appends (optional) to the label"
  attr :hint, :string, default: nil, doc: "a short helper line under the input"

  attr :prefix, :string,
    default: nil,
    doc: "what the value follows, in mono before a text input: the path a slug completes"

  attr :value, :any
  attr :size, :string, default: "sm", values: ~w(sm md), doc: "md (40 px) on auth pages"
  attr :debounce, :string, default: "blur", doc: "errors show after blur, not while typing"

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               radio search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "extra classes for the input element"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step spellcheck)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors =
      if Phoenix.Component.used_input?(field) or submitted_group?(assigns, field),
        do: field.errors,
        else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="grid gap-1.5">
      <label
        for={@id}
        class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10 has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-50"
      >
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={["checkbox checkbox-sm checkbox-primary", @class]}
          {@rest}
        />
        {@label}
      </label>
      <.error :for={{msg, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <fieldset class="fieldset">
      <.label :if={@label} for={@id} optional={@optional}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={["select", "select-#{@size}", @errors != [] && "select-error", @class]}
        multiple={@multiple}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={describedby(@id, @errors, @hint, @rest)}
        {without_describedby(@rest)}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={{msg, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "radio"} = assigns) do
    ~H"""
    <fieldset
      id={@id}
      class="fieldset"
      aria-invalid={@errors != [] && "true"}
      aria-describedby={describedby(@id, @errors, @hint)}
    >
      <legend :if={@label} class="mb-1 text-[13px]/[18px] font-medium">{@label}</legend>
      <label
        :for={{{label, value}, index} <- Enum.with_index(@options)}
        for={"#{@id}-#{index}"}
        class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
      >
        <input
          type="radio"
          id={"#{@id}-#{index}"}
          name={@name}
          value={value}
          checked={to_string(@value) == to_string(value)}
          class={["radio radio-sm radio-primary", @class]}
          {@rest}
        />
        {label}
      </label>
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={{msg, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>{msg}</.error>
    </fieldset>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <fieldset class="fieldset">
      <.label :if={@label} for={@id} optional={@optional}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={["textarea textarea-sm", @errors != [] && "input-error", @class]}
        phx-debounce={@debounce}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={describedby(@id, @errors, @hint, @rest)}
        {without_describedby(@rest)}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={{msg, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>{msg}</.error>
    </fieldset>
    """
  end

  # A text input with a prefix: the prefix in mono before it, as one field, the prefix
  # read with the value by whoever hears the field.
  def input(%{prefix: prefix} = assigns) when is_binary(prefix) do
    ~H"""
    <fieldset class="fieldset">
      <.label :if={@label} for={@id} optional={@optional}>{@label}</.label>
      <div class="q-input-prefix">
        <span id={"#{@id}-prefix"}>{@prefix}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={["input", "input-#{@size}", @errors != [] && "input-error", @class]}
          phx-debounce={@debounce}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={
            Enum.join(
              ["#{@id}-prefix", describedby(@id, @errors, @hint, @rest)] |> Enum.reject(&is_nil/1),
              " "
            )
          }
          {without_describedby(@rest)}
        />
      </div>
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={{msg, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>{msg}</.error>
    </fieldset>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <fieldset class="fieldset">
      <.label :if={@label} for={@id} optional={@optional}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["input", "input-#{@size}", @errors != [] && "input-error", @class]}
        phx-debounce={@debounce}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={describedby(@id, @errors, @hint, @rest)}
        {without_describedby(@rest)}
      />
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={{msg, i} <- Enum.with_index(@errors)} id={error_id(@id, i)}>{msg}</.error>
    </fieldset>
    """
  end

  # A radio group none of whose choices is picked sends nothing, so it is never a used
  # input: once its form is submitted, its errors show all the same.
  defp submitted_group?(%{type: "radio"}, %{form: %{source: %{action: action}}}),
    do: action in [:insert, :update]

  defp submitted_group?(_assigns, _field), do: false

  # What describes a field: its errors, else its hint, then whatever the page describes it
  # by too (an `aria-describedby` given to `input/1`, such as a hint the page draws
  # itself), so that neither hides the other.
  defp describedby(id, errors, hint, rest) do
    case Enum.reject([describedby(id, errors, hint), rest[:"aria-describedby"]], &blank?/1) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  defp describedby(id, [_ | _] = errors, _hint),
    do: errors |> Enum.with_index() |> Enum.map_join(" ", fn {_, i} -> error_id(id, i) end)

  defp describedby(id, [], hint) when is_binary(hint), do: "#{id}-hint"
  defp describedby(_id, _errors, _hint), do: nil

  defp blank?(ids), do: ids in [nil, false, ""]

  # The attributes given to `input/1` but the description, which `describedby/4` merges.
  defp without_describedby(rest), do: Map.delete(rest, :"aria-describedby")

  # A field may have more than one error, each of them a line of its own with an id of its
  # own: the first is the field's `-error`, as a test or a script looks for it.
  defp error_id(id, 0), do: "#{id}-error"
  defp error_id(id, i), do: "#{id}-error-#{i + 1}"

  attr :for, :string, default: nil
  attr :optional, :boolean, default: false
  slot :inner_block, required: true

  defp label(assigns) do
    ~H"""
    <label for={@for} class="text-[13px]/[18px] font-medium">
      {render_slot(@inner_block)}
      <span :if={@optional} class="font-normal text-faint">{gettext("(optional)")}</span>
    </label>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp hint(assigns) do
    ~H"""
    <p id={@id} class="text-[12.5px]/[18px] text-muted">{render_slot(@inner_block)}</p>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p id={@id} class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error">
      <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  ## Layout blocks

  @doc """
  switch/1 is a setting that is on or off and takes effect at once, without a Save: a
  `role="switch"` button with `aria-checked`, its label beside it (a `<label>`, which
  clicking also turns it), and one muted sentence under them as its description. A page
  turns it with `phx-click`; a switch whose state a script keeps, such as a reading
  preference of the browser, ignores `aria-checked` across patches
  (`phx-mounted={JS.ignore_attributes(["aria-checked"])}`), as the theme menu does.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-mounted phx-value-id)
  slot :inner_block, doc: "the description"

  def switch(assigns) do
    ~H"""
    <div class="q-toggle-line">
      <button
        id={@id}
        type="button"
        role="switch"
        class="q-toggle"
        aria-checked={to_string(@checked)}
        aria-describedby={@inner_block != [] && "#{@id}-description"}
        disabled={@disabled}
        {@rest}
      ></button>
      <label for={@id} class="q-toggle-label">{@label}</label>
      <p :if={@inner_block != []} id={"#{@id}-description"} class="q-toggle-description">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end

  @doc """
  Renders a page header: a title, an optional one-line description and at most
  one primary and one default action.

      <.header>
        Nodes
        <:subtitle>A node is one permanent machine; a node pool is a fleet of short-lived instances.</:subtitle>
        <:actions><.button variant="primary">New node</.button></:actions>
      </.header>
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["flex flex-wrap items-start justify-between gap-4", @class]}>
      <div class="min-w-0 flex-1 basis-72">
        <h1 class="text-xl/7 font-semibold tracking-[-0.017em] outline-none" tabindex="-1">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-0.5 max-w-[62ch] text-sm/5 text-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div
        :if={@actions != []}
        class="flex flex-none items-center gap-2 max-[479px]:w-full max-[479px]:[&>.btn]:flex-1"
      >
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  A bordered box with an optional header row and footer bar. Static cards
  never react to hover. Do not nest cards.
  """
  attr :class, :any, default: nil
  attr :padding, :boolean, default: true
  attr :rest, :global
  slot :inner_block, required: true
  slot :title
  slot :actions
  slot :footer

  def card(assigns) do
    ~H"""
    <section class={["card card-border bg-base-100 shadow-xs", @class]} {@rest}>
      <div
        :if={@title != []}
        class="flex min-h-[51px] flex-wrap items-center justify-between gap-x-3 gap-y-2 border-b border-line px-5 py-2"
      >
        <h2 class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
          {render_slot(@title)}
        </h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      <div class={@padding && "grid gap-4 p-5"}>
        {render_slot(@inner_block)}
      </div>
      <div
        :if={@footer != []}
        class="flex flex-wrap items-center justify-between gap-3 rounded-b-box border-t border-line bg-base-200 px-5 py-3 text-[12.5px]/[18px] text-muted"
      >
        {render_slot(@footer)}
      </div>
    </section>
    """
  end

  @doc """
  Summary figures as one bordered object with internal dividers.

      <.stats>
        <.stat label="Nodes" value={3} hint="running" navigate={~p"/\#{@current_scope.organisation}/\#{@current_scope.workspace}/nodes"} />
      </.stats>
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def stats(assigns) do
    ~H"""
    <div class={["stats border border-line bg-base-100 shadow-xs", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :navigate, :string, default: nil

  def stat(%{navigate: nil} = assigns) do
    ~H"""
    <div id={@id} class="stat">
      <div class="stat-title">{@label}</div>
      <div class="stat-value">{@value}</div>
      <div :if={@hint} class="stat-desc">{@hint}</div>
    </div>
    """
  end

  def stat(assigns) do
    ~H"""
    <.link id={@id} navigate={@navigate} class="stat">
      <div class="stat-title">{@label}</div>
      <div class="stat-value">{@value}</div>
      <div :if={@hint} class="stat-desc">{@hint}</div>
    </.link>
    """
  end

  @doc """
  A vertical list of numbered steps. Steps before `current` are done, the step
  at `current` is the current one, the rest are to do.

      <.steps current={2}>
        <:step title="Create an access key">Label it after the machine.</:step>
      </.steps>
  """
  attr :current, :integer, default: 1
  attr :class, :any, default: nil

  slot :step, required: true do
    attr :title, :string, required: true
  end

  def steps(assigns) do
    ~H"""
    <ol class={["q-steps", @class]}>
      <li
        :for={{step, n} <- Enum.with_index(@step, 1)}
        class={[n < @current && "q-step-done", n == @current && "q-step-current"]}
        aria-current={n == @current && "step"}
      >
        <span class="q-step-disc" aria-hidden={n < @current && "true"}>
          <%= if n < @current do %>
            <.icon name="hero-check-micro" class="size-3.5" />
          <% else %>
            {n}
          <% end %>
        </span>
        <div class="min-w-0">
          <p class="text-[13.5px]/6 font-medium">
            <span :if={n < @current} class="sr-only">{gettext("Done:")}</span>
            {step.title}
          </p>
          <p :if={step.inner_block} class="text-[13px]/[18px] text-muted">{render_slot(step)}</p>
        </div>
      </li>
    </ol>
    """
  end

  @doc """
  A quiet line that says the page is waiting for something.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def listening(assigns) do
    ~H"""
    <p id={@id} class={["flex items-center gap-2.5 text-[13px]/[18px] text-muted", @class]}>
      <span class="listening-dot mx-1" aria-hidden="true" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  An empty state: what is missing and the one next step. A list whose filters hide every
  row says so in words alone, with no tile (`icon={nil}`): the filters are the subject.
  """
  attr :icon, :any, default: "hero-key", doc: "the tile's icon, a string; nil for none"
  attr :title, :string, required: true
  attr :tone, :string, default: "honey", values: ~w(honey neutral)
  attr :heading, :string, default: "h2", values: ~w(h1 h2), doc: "h1 when it titles the page"
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "grid justify-items-center gap-1.5 rounded-box border border-dashed border-line-strong px-6 py-10 text-center",
      @class
    ]}>
      <.hex_tile :if={@icon} icon={@icon} tone={@tone} class="mb-2.5" />
      <%!-- As the page's h1 it takes the focus after a navigation, as every page's h1. --%>
      <.dynamic_tag
        tag_name={@heading}
        class="text-[15px]/[22px] font-semibold tracking-[-0.006em] outline-none"
        tabindex={@heading == "h1" && "-1"}
      >
        {@title}
      </.dynamic_tag>
      <div class="max-w-[46ch] text-[13.5px]/5 text-muted">{render_slot(@inner_block)}</div>
      <div :if={@actions != []} class="mt-3.5 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  The 44 px hexagon tile with an outline icon.
  """
  attr :icon, :string, required: true
  attr :tone, :string, default: "honey", values: ~w(honey neutral)
  attr :class, :any, default: nil

  def hex_tile(assigns) do
    ~H"""
    <div class={["hex-tile", @tone == "neutral" && "hex-tile-neutral", @class]} aria-hidden="true">
      <.icon name={@icon} class="size-5" />
    </div>
    """
  end

  @doc """
  A small label. Status badges carry a dot (`dot`), label badges do not. State
  is never colour alone: the word is always there.
  """
  attr :color, :string, default: "neutral", values: ~w(neutral success warning info error)
  attr :dot, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @dot && "badge-dot",
      @color == "success" && "border-transparent bg-success-soft text-success-soft-content",
      @color == "warning" && "border-transparent bg-primary-soft text-primary-soft-content",
      @color == "info" && "border-transparent bg-info-soft text-info-soft-content",
      @color == "error" && "border-transparent bg-error-soft text-error-soft-content",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A placeholder avatar: the first letter of a name. People are round, an
  organisation is square. Decorative: the name is always beside it.
  """
  attr :name, :string, default: nil
  attr :kind, :string, default: "person", values: ~w(person self organisation pending)
  attr :size, :string, default: "sm", values: ~w(xs sm md lg)
  attr :class, :any, default: nil

  def avatar(assigns) do
    ~H"""
    <span class={["avatar avatar-placeholder flex-none", @class]} aria-hidden="true">
      <div class={[
        @size == "xs" && "size-[18px] text-[10.5px]",
        @size == "sm" && "size-6 text-[11px]",
        @size == "md" && "size-7 text-xs",
        @size == "lg" && "size-8 text-[13px]",
        @kind == "person" && "rounded-full bg-base-300 text-muted ring-1 ring-inset ring-line",
        @kind == "self" && "rounded-full bg-primary-soft text-primary-soft-content",
        @kind == "organisation" && @size == "xs" && "rounded-selector bg-neutral text-neutral-content",
        @kind == "organisation" && @size != "xs" && "rounded-field bg-neutral text-neutral-content",
        @kind == "pending" &&
          "rounded-full border border-dashed border-line-field bg-transparent text-faint"
      ]}>
        <%= if @kind == "pending" do %>
          <.icon name="hero-envelope" class="size-3.5" />
        <% else %>
          {String.first(@name || "?")}
        <% end %>
      </div>
    </span>
    """
  end

  @doc """
  A block of preformatted text with a file name and a copy button. YAML keys
  take the accent colour; there is no other syntax colour. Without an `id` the
  block is a preview and has no copy button.
  """
  attr :id, :string, default: nil
  attr :code, :string, required: true
  attr :label, :string, default: nil
  attr :copy_label, :string, default: nil, doc: "defaults to Copy block"

  attr :wrap, :boolean,
    default: false,
    doc: "wraps long lines, breaking anywhere, instead of scrolling them: a command shown whole"

  attr :class, :any, default: nil

  def code_block(assigns) do
    assigns = assign(assigns, :highlighted, highlight_yaml(assigns.code))

    ~H"""
    <div class={["min-w-0 overflow-hidden rounded-box border border-line bg-code", @class]}>
      <div class={[
        "flex items-center justify-between border-b border-line pl-3.5 pr-1.5 font-mono text-xs/4 text-muted",
        if(@id, do: "py-1.5", else: "py-2.5")
      ]}>
        <span>{@label}</span>
        <.copy_button
          :if={@id}
          id={"#{@id}-copy"}
          text={@code}
          label={@copy_label || gettext("Copy block")}
        />
      </div>
      <pre
        id={@id}
        tabindex="0"
        class={[
          "p-3.5 font-mono text-[12.5px]/5 [tab-size:2]",
          if(@wrap, do: "whitespace-pre-wrap break-all", else: "overflow-x-auto")
        ]}
      ><code>{@highlighted}</code></pre>
    </div>
    """
  end

  # YAML keys in accent, placeholders (runs of middle dots) faint, nothing else.
  defp highlight_yaml(code) do
    lines =
      for line <- code |> String.trim_trailing() |> String.split("\n") do
        case Regex.run(~r/^(\s*)([A-Za-z_][\w.-]*):(.*)$/, line) do
          [_, indent, key, value] ->
            [indent, ~s(<span class="code-key">), escape(key), "</span>:", yaml_value(value)]

          _ ->
            escape(line)
        end
      end

    {:safe, Enum.intersperse(lines, "\n")}
  end

  defp yaml_value(value) do
    if String.contains?(value, "··"),
      do: [~s(<span class="code-faint">), escape(value), "</span>"],
      else: escape(value)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc """
  A short inline code span, for key ids and similar. `bare` drops the well,
  for table cells.
  """
  attr :bare, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def mono(assigns) do
    ~H"""
    <code
      phx-no-format
      class={[
        "font-mono text-[12.5px]",
        !@bare && "rounded-selector border border-line bg-code px-1.5 py-0.5",
        @class
      ]}
    >{render_slot(@inner_block)}</code>
    """
  end

  ## Links out

  @doc """
  A link to a page outside the console, which opens in a new tab: the icon shows that it
  leaves, and a screen reader hears that it opens a new tab. `rel` keeps the console's
  window and address from the page, and gives the link no weight. A url that is not
  `external_url?/1` (one with a user name or password among them), or none, renders the
  content as plain text with the same `class` and attributes, so a url from a record is
  never a `javascript:`, `data:` or relative link.
  """
  attr :href, :any, required: true, doc: "the url; nil, or one that may not be a link, for text"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def external_link(assigns) do
    assigns = assign(assigns, :link, external_url?(assigns.href))

    ~H"""
    <a
      :if={@link}
      href={@href}
      target="_blank"
      rel="noopener noreferrer nofollow"
      class={["q-link q-ext-link", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <.icon name="hero-arrow-top-right-on-square-micro" class="q-ext-icon size-3" />
      <span class="sr-only">{gettext("(opens in a new tab)")}</span>
    </a>
    <span :if={!@link} class={@class} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  Whether `url` may be a link out: an absolute `http` or `https` url with a host, and with
  no user name or password in it.
  """
  def external_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  def external_url?(_url), do: false

  ## Tables

  @doc """
  Renders a table inside a focusable scroll region, on the row spec (`docs/ui.md`, Lists):
  one line a row, its title the only strong text, every other cell small and muted.

  A column says what its cells are with `kind`: `"title"` for the row's name (14 px,
  medium, the text colour; a secondary word inside it takes `q-side`), `"hot"` for the
  one fact that needs someone, `"faint"` for what is tertiary, `"num"` for a count
  (right-aligned, tabular). `from` hides a column below a width of the table's own
  (`"sm"` 600 px, `"md"` 1000 px, `"lg"` 1300 px), so a table in a narrow pane reflows as
  on a narrow screen. A row's actions are its last column: a text action for the one
  thing a row's state asks for, and the rest in a `row_menu/1`; never a bordered button
  on every row, and never red outside a confirmation. A row asked to confirm an act on it
  (`confirming`, the row's id) shows the `confirm` slot in place of its cells, an
  `inline_confirm/1`, in one cell across the row; where the table is wider than its box,
  the confirmation stays in the box's view however far the table is scrolled sideways.

  ## Examples

      <.table id="users" label="Users" rows={@users}>
        <:col :let={user} label="Name" kind="title">{user.name}</:col>
        <:col :let={user} label="Joined" from="sm">{Format.date(user.inserted_at)}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the accessible name of the scroll region"
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :row_class, :any, default: nil, doc: "a function from a row to extra classes"
  attr :class, :any, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :sr_label, :string, doc: "a header for a screen reader only, for a column of icons"
    attr :class, :string
    attr :kind, :string, doc: "title, hot, faint or num"
    attr :from, :string, doc: "sm, md or lg: the table width from which the column shows"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  attr :confirming, :string,
    default: nil,
    doc: "the id of the row that is asking to confirm an act on it (`confirm` slot)"

  slot :confirm,
    doc:
      "what the row `confirming` names shows in place of its cells: an `inline_confirm/1`, given the row"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div
      class={["q-tbl overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs", @class]}
      tabindex="0"
      role="region"
      aria-label={@label}
    >
      <table class="table">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              scope="col"
              class={[head_class(col), col[:class]]}
            >
              {col[:label]}<span :if={col[:sr_label]} class="sr-only">{col[:sr_label]}</span>
            </th>
            <th :if={@action != []} scope="col" class="w-px">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={[
              @row_class && @row_class.(row),
              confirming?(@confirming, @row_id, row) && "q-confirming"
            ]}
          >
            <td
              :if={confirming?(@confirming, @row_id, row)}
              colspan={length(@col) + if(@action != [], do: 1, else: 0)}
              class="q-confirm-cell"
            >
              <div class="q-confirm-view">{render_slot(@confirm, @row_item.(row))}</div>
            </td>
            <td
              :for={col <- @col}
              :if={!confirming?(@confirming, @row_id, row)}
              phx-click={@row_click && @row_click.(row)}
              class={[@row_click && "cursor-pointer", col_class(col), col[:class]]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td
              :if={@action != [] && !confirming?(@confirming, @row_id, row)}
              class="cell-actions w-px text-right"
            >
              <div class="flex items-center justify-end gap-1">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp confirming?(nil, _row_id, _row), do: false
  defp confirming?(_id, nil, _row), do: false
  defp confirming?(id, row_id, row), do: row_id.(row) == id

  @doc """
  Renders a confirmation in place, where the act was asked for: never an overlay
  (`docs/ui.md`, Confirmations). A row of a table becomes one (`table/1`'s `confirming`
  and `confirm` slot), and so does a page's own control, such as a danger zone's line.

  It reads as one line that wraps: the question in the text colour ("Delete
  FORGE_TOKEN?"), what happens in a muted sentence, then its button, red for what cannot
  be undone ("Yes, delete"), and Cancel, which leads back (`cancel`, a patch) and takes
  the focus as it shows, so Enter does not act by mistake; Escape cancels too. The group
  is named by its question and described by the sentence (`id`-sub), so a screen reader
  says what happens, "This cannot be undone." included, as Cancel takes the focus.
  Where the act is itself a cancelling, `cancel_label` names the way back instead ("Keep
  it"), so the two buttons don't both say cancel.

      <.inline_confirm id="secret-1-confirm" question="Delete FORGE_TOKEN?" cancel={@list}>
        The secret and its value are deleted. This cannot be undone.
        <:action>
          <.button variant="danger" size="xs" phx-click="delete_secret" loading_text="Deleting">
            Yes, delete
          </.button>
        </:action>
      </.inline_confirm>
  """
  attr :id, :string, required: true

  attr :question, :any,
    required: true,
    doc: "the question, text or rich text (`ApiaryWeb.RichText`)"

  attr :cancel, :any,
    required: true,
    doc: "where Cancel leads: a path to patch to, or a JS command"

  attr :class, :any, default: nil

  attr :cancel_label, :string,
    default: nil,
    doc:
      "the words of the button that leads back, where Cancel would be ambiguous; Cancel unless given"

  slot :inner_block, doc: "what happens, one or two short sentences"
  slot :action, required: true, doc: "the button that acts"

  def inline_confirm(assigns) do
    assigns =
      assign(
        assigns,
        :cancel_js,
        if(is_binary(assigns.cancel), do: JS.patch(assigns.cancel), else: assigns.cancel)
      )

    ~H"""
    <div
      id={@id}
      role="group"
      aria-labelledby={"#{@id}-question"}
      aria-describedby={@inner_block != [] && "#{@id}-sub"}
      class={["q-confirm", @class]}
      phx-window-keydown={@cancel_js}
      phx-key="Escape"
    >
      <div class="q-confirm-what">
        <p id={"#{@id}-question"} class="q-confirm-q"><.rich text={@question} /></p>
        <p :if={@inner_block != []} id={"#{@id}-sub"} class="q-confirm-sub">
          {render_slot(@inner_block)}
        </p>
      </div>
      <div class="q-confirm-act">
        {render_slot(@action)}
        <button
          id={"#{@id}-cancel"}
          type="button"
          class="btn btn-xs"
          phx-click={@cancel_js}
          phx-mounted={JS.focus()}
        >
          {@cancel_label || gettext("Cancel")}
        </button>
      </div>
    </div>
    """
  end

  # A head cell takes its column's alignment and width, not the look of its cells.
  defp head_class(col) do
    [col[:kind] == "num" && "q-num", from_class(col[:from])]
  end

  defp col_class(col) do
    [
      case col[:kind] do
        "title" -> "q-td-title"
        "hot" -> "q-hot"
        "faint" -> "q-faint"
        "num" -> "q-num"
        _ -> nil
      end,
      from_class(col[:from])
    ]
  end

  defp from_class("sm"), do: "q-from-sm"
  defp from_class("md"), do: "q-from-md"
  defp from_class("lg"), do: "q-from-lg"
  defp from_class(_from), do: nil

  @doc """
  The ⋯ menu of a row: the actions a row offers beyond its one text action, under the
  `Menu` hook. The list floats in the top layer (`data-float`), so the table's scroll
  region never clips it. Its items are `menu_item/1`, with `menu_heading/1` and
  `menu_divider/1` between them; an edition's slot may add items of its own. A menu
  with no item shows no trigger.

      <.row_menu id={"key-\#{key.id}-menu"} label={gettext("Actions for %{label}", label: key.label)}>
        <.menu_item patch={rotate_path}>{gettext("Rotate…")}</.menu_item>
      </.row_menu>
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the trigger's accessible name, naming the row"
  attr :class, :any, default: nil
  slot :inner_block

  def row_menu(assigns) do
    assigns = assign(assigns, :items?, not blank_slot?(assigns.inner_block))

    ~H"""
    <div
      :if={@items?}
      id={@id}
      class={["q-rowmenu dropdown dropdown-end", @class]}
      phx-hook="Menu"
      data-float
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@id}-button"}
        type="button"
        class="q-rowmenu-btn btn btn-ghost btn-xs btn-square"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={@label}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-ellipsis-horizontal-micro" class="size-4" />
      </button>
      <ul
        class="q-rowmenu-list menu menu-sm dropdown-content"
        role="menu"
        aria-label={@label}
        popover="manual"
        phx-mounted={JS.ignore_attributes(["style"])}
      >
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  # Whether a slot renders nothing but whitespace: absent, or each of its items left out
  # by its `:if`. It renders the slot on its own, apart from the template's render, so the
  # menu's markup keeps its change tracking.
  defp blank_slot?([]), do: true

  defp blank_slot?(slot) do
    assigns = %{slot: slot}

    ~H"{render_slot(@slot)}"
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> String.trim()
    |> Kernel.==("")
  end

  @doc """
  An item of a menu (`row_menu/1`, `filter_menu/1`, `sort_menu/1`): a link when given
  `navigate`, `patch` or `href`, else a button. `checked` makes it one of a set
  (`menuitemradio`, or `menuitemcheckbox` with `multiple`) with its mark; `hint` is a
  faint line under its words. It is never red: a destructive act opens its confirm
  dialog, which is.
  """
  attr :rest, :global, include: ~w(href navigate patch method disabled)
  attr :checked, :any, default: nil, doc: "true or false for one of a set; nil for an act"
  attr :multiple, :boolean, default: false
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def menu_item(assigns) do
    assigns =
      assign(assigns,
        role:
          cond do
            is_nil(assigns.checked) -> "menuitem"
            assigns.multiple -> "menuitemcheckbox"
            true -> "menuitemradio"
          end,
        link?: assigns.rest[:href] || assigns.rest[:navigate] || assigns.rest[:patch]
      )

    ~H"""
    <li role="none" class={["q-mi", @hint && "q-mi-hint", @class]}>
      <.link
        :if={@link?}
        role={@role}
        tabindex="-1"
        aria-checked={!is_nil(@checked) && to_string(@checked)}
        {@rest}
      >
        <.menu_check :if={!is_nil(@checked)} checked={@checked} />
        <span class="q-mi-t">{render_slot(@inner_block)}<span :if={@hint}>{@hint}</span></span>
      </.link>
      <button
        :if={!@link?}
        type="button"
        role={@role}
        tabindex="-1"
        aria-checked={!is_nil(@checked) && to_string(@checked)}
        data-menu-close
        {@rest}
      >
        <.menu_check :if={!is_nil(@checked)} checked={@checked} />
        <span class="q-mi-t">{render_slot(@inner_block)}<span :if={@hint}>{@hint}</span></span>
      </button>
    </li>
    """
  end

  attr :checked, :boolean, required: true

  defp menu_check(assigns) do
    ~H"""
    <span class="q-mi-ck" aria-hidden="true">
      <.icon :if={@checked} name="hero-check-micro" class="size-4" />
    </span>
    """
  end

  @doc "A menu's heading: what the items under it are about, and an optional faint line."
  attr :title, :string, required: true
  attr :sub, :string, default: nil

  def menu_heading(assigns) do
    ~H"""
    <li role="presentation" class="q-mh">
      <span class="q-mh-t">{@title}</span>
      <span :if={@sub} class="q-mh-s">{@sub}</span>
    </li>
    """
  end

  @doc "A rule between two groups of a menu's items."
  def menu_divider(assigns) do
    ~H"""
    <li role="separator" class="menu-divider"></li>
    """
  end

  @doc """
  A row's state in words, said only when it is not the usual one ("Rotated",
  "Suspended", "Revoked 2 Sept"). Plain muted text; `hot` lifts it to the text colour
  with a dot of `tone` for a state that needs someone. Never a pill.
  """
  attr :id, :string, default: nil
  attr :hot, :boolean, default: false
  attr :tone, :string, default: "warning", values: ~w(warning error info)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def state_word(assigns) do
    ~H"""
    <span id={@id} class={["q-stw", @hot && "q-stw-hot q-stw-#{@tone}", @class]}>
      <span :if={@hot} class="q-stw-dot" aria-hidden="true"></span>{render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Runs a day as small bars, oldest first, the last one (today) in ink: a shape to read at
  a glance, not a chart to read values from; the numbers beside it say how many.
  """
  attr :values, :list, required: true
  attr :class, :any, default: nil

  def sparkline(assigns) do
    max = Enum.max([1 | assigns.values])
    count = max(length(assigns.values), 1)

    bars =
      assigns.values
      |> Enum.with_index()
      |> Enum.map(fn {n, i} ->
        h = if n == 0, do: 1, else: max(2, round(n / max * 18))
        %{x: i * 6, h: h, today: i == count - 1, zero: n == 0}
      end)

    assigns = assign(assigns, bars: bars, width: count * 6 - 1)

    ~H"""
    <svg
      class={["q-spark", @class]}
      viewBox={"0 0 #{@width} 18"}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <rect
        :for={bar <- @bars}
        x={bar.x}
        y={18 - bar.h}
        width="5"
        height={bar.h}
        class={[bar.today && "q-spark-today", bar.zero && "q-spark-zero"]}
      />
    </svg>
    """
  end

  ## List controls

  @doc """
  A list's views, as tabs over it: a few stored filters, each a link with its count, the
  current one marked `aria-current="page"` (`docs/ui.md`, Lists).

      <.views label={gettext("Views")}>
        <:view patch={~p"/..."} count={50} current>{gettext("All")}</:view>
      </.views>
  """
  attr :id, :string, default: nil
  attr :label, :string, required: true

  slot :view, required: true do
    attr :id, :string
    attr :patch, :string
    attr :navigate, :string
    attr :count, :any
    attr :current, :boolean
  end

  def views(assigns) do
    ~H"""
    <nav id={@id} class="q-views" aria-label={@label}>
      <.link
        :for={view <- @view}
        id={view[:id]}
        patch={view[:patch]}
        navigate={view[:navigate]}
        aria-current={view[:current] && "page"}
      >
        {render_slot(view)}<span :if={view[:count]} class="q-views-n">{view[:count]}</span>
      </.link>
    </nav>
    """
  end

  @doc """
  A list's search: one field, sent as the reader types (`change`, 200 ms after they stop)
  and on Enter. Its value lives in the page's URL, which the page patches. `live={false}`
  sends it on Enter only, for a query whose words are read as a whole (qualifiers such as
  `state:failed`, which the page turns into filters).

  `suggest` makes the field a combobox (the ARIA list autocomplete, manual selection): the
  form sends `suggest` 150 ms after the reader stops typing, and the page answers with
  `suggestions`, `%{value:, detail:}` each, at most a handful, listed under the field as
  options of the listbox `<id>-hosts`, and `status`, what a screen reader is told of them.
  The `HostSuggest` hook moves among them with ↑ and ↓; Enter or a click puts the chosen
  one in place of the word being typed, as `host:<value>`, and sends the query; Escape,
  Tab and leaving the field close the list.
  """
  attr :id, :string, required: true
  attr :name, :string, default: "q"
  attr :value, :string, default: nil
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :change, :string, default: "search", doc: "the event the form sends"
  attr :live, :boolean, default: true
  attr :class, :any, default: nil
  attr :suggest, :string, default: nil, doc: "the event that asks for suggestions; nil for none"
  attr :suggestions, :list, default: [], doc: "`%{value:, detail:}` each, as the page answered"
  attr :suggestions_label, :string, default: nil, doc: "the listbox's accessible name"
  attr :status, :string, default: nil, doc: "what the answer is, for a screen reader"

  def list_search(assigns) do
    ~H"""
    <form
      id={@id}
      class={["q-find", @suggest && "q-find-suggest", @class]}
      role="search"
      phx-change={(@live && @change) || @suggest}
      phx-submit={@change}
      phx-hook={@suggest && "HostSuggest"}
      data-suggest={@suggest}
      novalidate
    >
      <label>
        <.icon name="hero-magnifying-glass" class="q-find-i size-4" />
        <span class="sr-only">{@label}</span>
        <input
          id={"#{@id}-input"}
          type="search"
          name={@name}
          value={@value}
          placeholder={@placeholder || @label}
          autocomplete="off"
          spellcheck="false"
          phx-debounce={(@live && "200") || (@suggest && "150")}
          enterkeyhint="search"
          class="input input-sm"
          role={@suggest && "combobox"}
          aria-autocomplete={@suggest && "list"}
          aria-controls={@suggest && "#{@id}-hosts"}
          aria-expanded={@suggest && to_string(@suggestions != [])}
        />
      </label>
      <ul
        :if={@suggest}
        id={"#{@id}-hosts"}
        class="q-suggest"
        role="listbox"
        aria-label={@suggestions_label}
        hidden={@suggestions == []}
      >
        <li
          :for={{suggestion, i} <- Enum.with_index(@suggestions)}
          id={"#{@id}-host-#{i}"}
          role="option"
          aria-selected="false"
          data-value={suggestion.value}
        >
          <span class="q-suggest-v">{suggestion.value}</span>
          <span :if={suggestion[:detail]} class="q-suggest-d">{suggestion.detail}</span>
        </li>
      </ul>
      <p :if={@suggest} id={"#{@id}-status"} class="sr-only" role="status">{@status}</p>
    </form>
    """
  end

  @doc """
  The one Filter menu of a list: its sections, each a heading and the values that narrow
  the list by it, as `menu_item/1`s (`checked` and `multiple`); what is chosen shows under
  the bar as `filter_tokens/1`. `count` is how many filters are on.

  A list whose sections hold more values than a menu can (a list of runs: hundreds of
  targets, thousands of tasks) gives `section`s instead: the menu is then a dialog that
  lists the sections, each with the word the query writes it with (`qualifier`) or what it
  is set to (`value`), and opens the one chosen in its place, with a way back. A section's
  content is the slot's: a form that searches its values on the server and sets the
  filter (`ApiaryWeb.RunComponents.filter_options/1`). Moving between the two is done in
  the browser (`Phoenix.LiveView.JS`), so a section opens at once and stays open while
  the page patches. A section marked `rail` is one the page's rail does from 1280 px, and
  shows only below it.
  """
  attr :id, :string, required: true
  attr :count, :integer, default: 0
  slot :inner_block

  slot :section do
    attr :key, :string, required: true
    attr :label, :string, required: true
    attr :icon, :string, required: true
    attr :qualifier, :string
    attr :value, :string
    attr :rail, :boolean
  end

  def filter_menu(%{section: [_ | _]} = assigns) do
    ~H"""
    <div
      id={@id}
      class="q-listmenu q-fm dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-sm"
        aria-controls={"#{@id}-panel"}
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={
          JS.show(to: "##{@id}-sections")
          |> JS.hide(to: "##{@id}-panel .q-fm-section")
        }
      >
        <.icon name="hero-funnel" class="size-4 text-faint" />{gettext("Filter")}
        <span :if={@count > 0} class="q-listmenu-n">{@count}</span>
      </button>
      <div
        id={"#{@id}-panel"}
        role="group"
        aria-label={gettext("Filter")}
        class="dropdown-content q-fm-panel"
        tabindex="-1"
      >
        <div id={"#{@id}-sections"} class="q-fm-sections">
          <p class="q-fm-h" aria-hidden="true">{gettext("Filter by")}</p>
          <button
            :for={section <- @section}
            id={"#{@id}-open-#{section.key}"}
            type="button"
            class={["q-fm-opt", section[:rail] && "q-norail"]}
            aria-describedby={section[:value] && "#{@id}-value-#{section.key}"}
            phx-click={
              JS.show(to: "##{@id}-section-#{section.key}")
              |> JS.hide(to: "##{@id}-sections")
              |> JS.focus_first(to: "##{@id}-body-#{section.key}")
            }
          >
            <.icon name={section.icon} class="size-3.5" />
            <span class="q-fm-label">{section.label}</span>
            <span
              :if={section[:value]}
              id={"#{@id}-value-#{section.key}"}
              class="q-fm-value"
              title={section[:value]}
            >
              {section[:value]}
            </span>
            <span :if={!section[:value] && section[:qualifier]} class="q-fm-meta" aria-hidden="true">
              {section.qualifier}:
            </span>
          </button>
        </div>
        <div
          :for={section <- @section}
          id={"#{@id}-section-#{section.key}"}
          class="q-fm-section hidden"
          role="group"
          aria-labelledby={"#{@id}-title-#{section.key}"}
        >
          <div class="q-fm-head">
            <button
              type="button"
              class="q-fm-back"
              aria-label={gettext("Back to every filter")}
              phx-click={
                JS.show(to: "##{@id}-sections")
                |> JS.focus(to: "##{@id}-open-#{section.key}")
                |> JS.hide(to: "##{@id}-section-#{section.key}")
              }
            >
              <.icon name="hero-chevron-left-micro" class="size-4" />
            </button>
            <p id={"#{@id}-title-#{section.key}"} class="q-fm-title">{section.label}</p>
          </div>
          <div id={"#{@id}-body-#{section.key}"}>{render_slot(section)}</div>
        </div>
      </div>
    </div>
    """
  end

  def filter_menu(assigns) do
    ~H"""
    <div
      id={@id}
      class="q-listmenu dropdown dropdown-end"
      phx-hook="Menu"
      data-float
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-sm"
        aria-haspopup="menu"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-funnel" class="size-4 text-faint" />{gettext("Filter")}
        <span :if={@count > 0} class="q-listmenu-n">{@count}</span>
      </button>
      <ul
        class="q-rowmenu-list q-listmenu-list menu menu-sm dropdown-content"
        role="menu"
        aria-label={gettext("Filter")}
        popover="manual"
        phx-mounted={JS.ignore_attributes(["style"])}
      >
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  A list's Sort: the orders it can be read in, as `menu_item/1`s with `checked`; the
  trigger names the order in force, in words short enough for a button (`label`, else
  `current`), and in full for a screen reader.
  """
  attr :id, :string, required: true
  attr :current, :string, required: true, doc: "the order in force, in words"
  attr :label, :string, default: nil, doc: "the order in force as the button says it"
  slot :inner_block, required: true

  def sort_menu(assigns) do
    ~H"""
    <div
      id={@id}
      class="q-listmenu dropdown dropdown-end"
      phx-hook="Menu"
      data-float
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-sm"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("Sort: %{order}", order: @current)}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-arrows-up-down" class="size-4 text-faint" />{@label || @current}
      </button>
      <ul
        class="q-rowmenu-list q-listmenu-list menu menu-sm dropdown-content"
        role="menu"
        aria-label={gettext("Sort")}
        popover="manual"
        phx-mounted={JS.ignore_attributes(["style"])}
      >
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  @doc """
  The filters in force, under a list's bar: each a token that says what it keeps and a
  link that takes it away, and "Clear" for them all. Nothing when none is on.
  """
  attr :id, :string, required: true
  attr :clear, :string, default: nil, doc: "the path with no filter on"

  slot :token do
    attr :id, :string
    attr :patch, :any, required: true, doc: "nil for a token that cannot be taken away"
    attr :label, :string, required: true, doc: "what taking it away says, for a screen reader"
    attr :class, :string, doc: "q-tok-q for a query's word, `qualifier:value`"
  end

  slot :inner_block, doc: "after the tokens: how many the filters keep, say"

  def filter_tokens(assigns) do
    ~H"""
    <div :if={@token != []} id={@id} class="q-tokens">
      <span :for={token <- @token} id={token[:id]} class={["q-tok", token[:class]]}>
        {render_slot(token)}
        <.link :if={token.patch} patch={token.patch} aria-label={token.label} class="q-tok-x">
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </.link>
      </span>
      <.link :if={@clear} id={"#{@id}-clear"} patch={@clear} class="q-tok-clear">
        {gettext("Clear")}
      </.link>
      {render_slot(@inner_block)}
    </div>
    """
  end

  ## Icons

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles: outline, solid, and mini. By default the
  outline style is used; solid, mini and micro may be applied by the `-solid`,
  `-mini` and `-micro` suffix.

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## Time

  @doc """
  A timestamp as people say it, up to seven days back ("2 minutes ago",
  "Yesterday, 17:20"), then the date (`ApiaryWeb.Format.time_ago/2`). The full time with
  its zone is in the `title`.
  """
  attr :at, :any, required: true
  attr :class, :any, default: nil

  def time_ago(assigns) do
    ~H"""
    <time
      datetime={DateTime.to_iso8601(@at)}
      title={Format.datetime(@at, zone: true)}
      class={@class}
    >
      {Format.time_ago(@at)}
    </time>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 180,
      transition:
        {"transition-all ease-out duration-[180ms]", "opacity-0 translate-y-1",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 120,
      transition:
        {"transition-all ease-in duration-[120ms]", "opacity-100 translate-y-0",
         "opacity-0 translate-y-1"}
    )
  end

  @doc """
  Translates a changeset's error message, in the `errors` Gettext domain.
  """
  @spec translate_error({String.t(), keyword}) :: String.t()
  def translate_error({msg, opts}) do
    # The message is marked where it is written (`dgettext_noop("errors", ...)`), by the
    # core or by the edition, and only its text reaches the form: it is looked up in the
    # core's catalogues, then in the edition's.
    backends = ApiaryWeb.Gettext.Backends.all()

    if count = opts[:count] do
      ApiaryWeb.Gettext.Backends.dngettext(backends, "errors", msg, msg, count, opts)
    else
      ApiaryWeb.Gettext.Backends.dgettext(backends, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
