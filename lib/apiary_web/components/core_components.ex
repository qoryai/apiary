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

  alias Phoenix.LiveView.JS

  # Qory's words and the standard term they show on hover.
  @terms %{
    "apiary" => "organisation",
    "apiaries" => "organisations",
    "hive" => "workplace",
    "hives" => "workplaces"
  }

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
  the no-hive top bar and the auth header strip (22 px mark), `lg` the auth
  panel (28 px mark).
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

  Not for the tenant or the hive: a page says organisation and hive through Gettext, and
  the body's catalogue says workplace (`docs/lingo.md`). The `apiary` and `hive` entries
  serve the pages not converted yet.
  """
  attr :word, :string, required: true
  attr :standard, :string, default: nil, doc: "override the standard term"
  attr :class, :any, default: nil

  def term(assigns) do
    standard = assigns.standard || Map.get(@terms, String.downcase(assigns.word), assigns.word)
    assigns = assign(assigns, :standard, standard)

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
  An inline notice: a soft fill, an icon, no close button.
  """
  attr :kind, :atom, default: :info, values: [:info, :warning, :error]
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
        @class
      ]}
    >
      <.icon
        name={
          case @kind do
            :info -> "hero-information-circle-micro"
            :warning -> "hero-exclamation-triangle-micro"
            :error -> "hero-exclamation-circle-micro"
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
  submits or its click is in flight; the button keeps its width.

  ## Examples

      <.button variant="primary" loading_text="Saving">Save</.button>
      <.button navigate={~p"/hive"}>Back</.button>
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

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@classes} data-busy={@loading_text && ""} {@rest}>
        <%= if @loading_text do %>
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
        <span class="copy-idle"><.icon name="hero-clipboard-document-micro" class="size-4" /></span>
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
        <.icon name="hero-clipboard-document-micro" class="size-4" />{@label}
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
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :optional, :boolean, default: false, doc: "appends (optional) to the label"
  attr :hint, :string, default: nil, doc: "a short helper line under the input"
  attr :value, :any
  attr :size, :string, default: "sm", values: ~w(sm md), doc: "md (40 px) on auth pages"
  attr :debounce, :string, default: "blur", doc: "errors show after blur, not while typing"

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

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
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

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
      <.error :for={msg <- @errors} id={"#{@id}-error"}>{msg}</.error>
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
        aria-describedby={describedby(@id, @errors, @hint)}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={msg <- @errors} id={"#{@id}-error"}>{msg}</.error>
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
        aria-describedby={describedby(@id, @errors, @hint)}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={msg <- @errors} id={"#{@id}-error"}>{msg}</.error>
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
        aria-describedby={describedby(@id, @errors, @hint)}
        {@rest}
      />
      <.hint :if={@hint && @errors == []} id={"#{@id}-hint"}>{@hint}</.hint>
      <.error :for={msg <- @errors} id={"#{@id}-error"}>{msg}</.error>
    </fieldset>
    """
  end

  defp describedby(id, [_ | _], _hint), do: "#{id}-error"
  defp describedby(id, [], hint) when is_binary(hint), do: "#{id}-hint"
  defp describedby(_id, _errors, _hint), do: nil

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
  Renders a page header: a title, an optional one-line description and at most
  one primary and one default action.

      <.header>
        Access keys
        <:subtitle>Keys let machines post runs to this hive.</:subtitle>
        <:actions><.button variant="primary">New access key</.button></:actions>
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
        <h1 class="text-xl/7 font-semibold tracking-[-0.017em]">
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
        <.stat label="Access keys" value={3} hint="active" navigate={~p"/hive/keys"} />
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
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def listening(assigns) do
    ~H"""
    <p class={["flex items-center gap-2.5 text-[13px]/[18px] text-muted", @class]}>
      <span class="listening-dot mx-1" aria-hidden="true" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  An empty state: what is missing and the one next step.
  """
  attr :icon, :string, default: "hero-key"
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
      <.hex_tile icon={@icon} tone={@tone} class="mb-2.5" />
      <.dynamic_tag tag_name={@heading} class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
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
  apiary is square. Decorative: the name is always beside it.
  """
  attr :name, :string, default: nil
  attr :kind, :string, default: "person", values: ~w(person self apiary pending)
  attr :size, :string, default: "sm", values: ~w(sm md lg)
  attr :class, :any, default: nil

  def avatar(assigns) do
    ~H"""
    <span class={["avatar avatar-placeholder flex-none", @class]} aria-hidden="true">
      <div class={[
        @size == "sm" && "size-6 text-[11px]",
        @size == "md" && "size-7 text-xs",
        @size == "lg" && "size-8 text-[13px]",
        @kind == "person" && "rounded-full bg-base-300 text-muted ring-1 ring-inset ring-line",
        @kind == "self" && "rounded-full bg-primary-soft text-primary-soft-content",
        @kind == "apiary" && "rounded-field bg-neutral text-neutral-content",
        @kind == "pending" &&
          "rounded-full border border-dashed border-line-field bg-transparent text-faint"
      ]}>
        <%= if @kind == "pending" do %>
          <.icon name="hero-envelope-micro" class="size-3.5" />
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
        class="overflow-x-auto p-3.5 font-mono text-[12.5px]/5 [tab-size:2]"
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

  ## Tables

  @doc """
  Renders a table inside a focusable scroll region.

  ## Examples

      <.table id="users" label="Users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :label, :string, default: nil, doc: "the accessible name of the scroll region"
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
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div
      class={["overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs", @class]}
      tabindex="0"
      role="region"
      aria-label={@label || @id}
    >
      <table class="table">
        <thead>
          <tr>
            <th :for={col <- @col} scope="col" class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []} scope="col" class="w-px">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={@row_class && @row_class.(row)}
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[@row_click && "cursor-pointer", col[:class]]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="cell-actions w-px text-right">
              <div class="flex items-center justify-end gap-0.5">
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

  ## Modal

  @doc """
  Renders a modal on the native `<dialog>`: focus is trapped, the background is
  inert and Escape works for free. Render it conditionally (for example on a
  live action) and pass an `on_cancel` JS command, usually a patch back to the
  index. `dismissable={false}` leaves the footer's button as the only exit.

      <.modal :if={@live_action == :new} id="new-key" on_cancel={JS.patch(~p"/hive/keys")} title="New access key">
        ...
        <:footer>
          <.button patch={~p"/hive/keys"}>Cancel</.button>
        </:footer>
      </.modal>

  Initial focus goes to the element marked `data-autofocus`, else the first
  field, else the primary button. Mark Cancel in destructive confirms.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, JS, default: %JS{}
  attr :dismissable, :boolean, default: true, doc: "close on escape, click outside and the X"
  attr :size, :string, default: "md", values: ~w(sm md lg)
  slot :inner_block, required: true
  slot :aside, doc: "sits at the right of the title, for example a badge"
  slot :footer

  def modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      phx-hook="Modal"
      data-cancel={@dismissable && @on_cancel}
      aria-labelledby={"#{@id}-title"}
      class="modal modal-bottom sm:modal-middle"
    >
      <div class={[
        "modal-box",
        @size == "sm" && "sm:max-w-[400px]",
        @size == "md" && "sm:max-w-[480px]",
        @size == "lg" && "sm:max-w-[560px]"
      ]}>
        <div class="flex items-start justify-between gap-3 px-5 pt-5">
          <h2
            id={"#{@id}-title"}
            class="min-w-0 break-words text-base/6 font-semibold tracking-[-0.01em]"
          >
            {@title}
          </h2>
          <div :if={@aside != []} class="flex h-6 flex-none items-center">
            {render_slot(@aside)}
          </div>
          <.tooltip :if={@dismissable} tip={gettext("Close")} placement="left" class="flex-none">
            <button
              type="button"
              phx-click={@on_cancel}
              class="btn btn-ghost btn-xs btn-square btn-keep"
              aria-label={gettext("Close")}
            >
              <.icon name="hero-x-mark-micro" class="size-4" />
            </button>
          </.tooltip>
        </div>
        <div class="modal-body grid min-h-0 gap-4 overflow-y-auto px-5 pb-5 pt-2 text-[13.5px]/5">
          {render_slot(@inner_block)}
        </div>
        <div :if={@footer != []} class="modal-action flex-none">
          {render_slot(@footer)}
        </div>
      </div>
      <form :if={@dismissable} method="dialog" class="modal-backdrop">
        <button tabindex="-1" aria-hidden="true">{gettext("Close")}</button>
      </form>
    </dialog>
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

  ## Formatting

  @doc "A short date: 12 Sep 2026."
  def short_date(nil), do: nil
  def short_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y")
  def short_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y")

  @doc "A short date and time in UTC: 12 Sep 2026, 14:03 UTC."
  def short_datetime(nil), do: nil
  def short_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y, %H:%M UTC")
  def short_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y, %H:%M UTC")

  @doc """
  A timestamp as people say it, up to seven days back ("2 minutes ago",
  "Yesterday, 17:20"), then the short date. The absolute time is in the `title`.
  """
  attr :at, :any, required: true
  attr :class, :any, default: nil

  def time_ago(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={short_datetime(@at)} class={@class}>
      {relative_time(@at)}
    </time>
    """
  end

  @doc false
  def relative_time(%DateTime{} = at, now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, at, :second), 0)
    days = Date.diff(DateTime.to_date(now), DateTime.to_date(at))

    cond do
      seconds < 60 ->
        gettext("Just now")

      seconds < 3600 ->
        ngettext("%{count} minute ago", "%{count} minutes ago", div(seconds, 60))

      days == 0 ->
        ngettext("%{count} hour ago", "%{count} hours ago", div(seconds, 3600))

      days == 1 ->
        gettext("Yesterday, %{time}", time: Calendar.strftime(at, "%H:%M"))

      days <= 7 ->
        ngettext("%{count} day ago", "%{count} days ago", days)

      true ->
        short_date(at)
    end
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
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(ApiaryWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(ApiaryWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
