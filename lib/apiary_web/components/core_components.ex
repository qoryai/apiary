defmodule ApiaryWeb.CoreComponents do
  @moduledoc """
  Core UI components for Apiary.

  Bespoke Tailwind v4 components on top of the design tokens in
  `assets/css/app.css` (`bg-surface`, `text-ink-muted`, `border-line`,
  `bg-accent`, `rounded-field`, `rounded-box`, `shadow-low`, `shadow-pop`).

  Icons come from [Heroicons](https://heroicons.com), see `icon/1`.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  alias Phoenix.LiveView.JS

  # Apiary words and the standard term they show on hover.
  @terms %{
    "apiary" => "organisation",
    "apiaries" => "organisations",
    "hive" => "team",
    "hives" => "teams"
  }

  ## Brand

  @doc """
  The hexagon logo mark.
  """
  attr :class, :any, default: "size-7"

  def logo_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 32 32" fill="none" aria-hidden="true" class={["logo-mark shrink-0", @class]}>
      <path
        d="M16 2.5 27.7 9.25v13.5L16 29.5 4.3 22.75V9.25L16 2.5Z"
        fill="currentColor"
        fill-opacity="0.18"
        stroke="currentColor"
        stroke-width="2"
        stroke-linejoin="round"
      />
      <path
        d="M16 9.5 21.6 12.75v6.5L16 22.5l-5.6-3.25v-6.5L16 9.5Z"
        fill="currentColor"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @doc """
  Logo mark with the wordmark.
  """
  attr :class, :any, default: nil
  attr :href, :string, default: "/"

  def brand(assigns) do
    ~H"""
    <a href={@href} class={["inline-flex items-center gap-2.5 text-ink", @class]}>
      <.logo_mark class="size-7" />
      <span class="text-[15px] font-semibold tracking-tight">Apiary</span>
    </a>
    """
  end

  ## Vocabulary

  @doc """
  Renders an apiary word with its standard term on hover.

      <.term word="apiary" />        # <abbr title="organisation">apiary</abbr>
      <.term word="Hive" />          # <abbr title="team">Hive</abbr>
  """
  attr :word, :string, required: true
  attr :standard, :string, default: nil, doc: "override the standard term"
  attr :class, :any, default: nil

  def term(assigns) do
    standard = assigns.standard || Map.get(@terms, String.downcase(assigns.word), assigns.word)
    assigns = assign(assigns, :standard, standard)

    ~H"""
    <abbr title={@standard} class={@class}>{@word}</abbr>
    """
  end

  ## Feedback

  @doc """
  Renders a flash notice as a toast.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash id="welcome-back" kind={:info} phx-mounted={show("#welcome-back")} hidden>
        Welcome back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "pointer-events-auto flex w-80 items-start gap-3 rounded-box border bg-surface p-4",
        "text-sm shadow-pop sm:w-96",
        @kind == :info && "border-line",
        @kind == :error && "border-danger/40"
      ]}
      {@rest}
    >
      <.icon
        :if={@kind == :info}
        name="hero-check-circle-mini"
        class="mt-0.5 size-5 shrink-0 text-success"
      />
      <.icon
        :if={@kind == :error}
        name="hero-exclamation-circle-mini"
        class="mt-0.5 size-5 shrink-0 text-danger"
      />
      <div class="min-w-0 flex-1 text-ink">
        <p :if={@title} class="font-semibold">{@title}</p>
        <p class="text-ink-muted">{msg}</p>
      </div>
      <button
        type="button"
        class="-m-1 rounded-md p-1 text-ink-faint transition hover:text-ink"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>
    """
  end

  ## Buttons

  @doc """
  Renders a button, or a link styled as one when `href`, `navigate` or `patch` is given.

  ## Examples

      <.button variant="primary">Save</.button>
      <.button navigate={~p"/hive"}>Back</.button>
      <.button variant="danger" phx-click="revoke">Revoke</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any, default: nil
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md)
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
      <button class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_classes(assigns) do
    [
      "inline-flex cursor-pointer select-none items-center justify-center gap-1.5 whitespace-nowrap",
      "rounded-field border font-medium transition",
      "disabled:cursor-not-allowed disabled:opacity-50",
      "phx-submit-loading:opacity-70 phx-click-loading:opacity-70",
      size_classes(assigns.size),
      variant_classes(assigns.variant),
      assigns.class
    ]
  end

  defp size_classes("sm"), do: "h-8 px-2.5 text-[13px]"
  defp size_classes("md"), do: "h-9 px-3.5 text-sm"

  defp variant_classes("primary"),
    do: "border-transparent bg-accent text-accent-ink shadow-low hover:bg-accent-hover"

  defp variant_classes("secondary"),
    do: "border-line-strong bg-surface text-ink shadow-low hover:bg-surface-2"

  defp variant_classes("ghost"),
    do: "border-transparent bg-transparent text-ink-muted hover:bg-surface-2 hover:text-ink"

  defp variant_classes("danger"),
    do: "border-transparent bg-danger text-ink-inverse shadow-low hover:bg-danger-hover"

  @doc """
  A copy-to-clipboard button. Copies `text`, or the text content of the
  element `target` selects, via the CopyToClipboard hook.
  """
  attr :id, :string, required: true
  attr :text, :string, default: nil
  attr :target, :string, default: nil, doc: "a CSS selector whose text content is copied"
  attr :label, :string, default: "Copy"
  attr :size, :string, default: "sm", values: ~w(sm md)
  attr :class, :any, default: nil

  def copy_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-hook="CopyToClipboard"
      data-copy={@text}
      data-copy-target={@target}
      class={[
        "copy-btn inline-flex cursor-pointer items-center gap-1.5 rounded-field border border-line-strong",
        "bg-surface font-medium text-ink-muted shadow-low transition hover:bg-surface-2 hover:text-ink",
        "data-copied:border-success/50 data-copied:text-success",
        size_classes(@size),
        @class
      ]}
      aria-label={"#{@label} to clipboard"}
    >
      <span class="copy-label-idle">
        <.icon name="hero-clipboard-document-micro" class="size-4" />
        {@label}
      </span>
      <span class="copy-label-done">
        <.icon name="hero-check-micro" class="size-4" /> Copied
      </span>
    </button>
    """
  end

  ## Forms

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument, which is used to
  retrieve the input name, id, and values. Otherwise all attributes may be
  passed explicitly.

  ## Examples

      <.input field={@form[:email]} type="email" label="Email" />
      <.input field={@form[:level]} type="select" options={[Owner: "owner"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil, doc: "a short helper line under the input"
  attr :value, :any

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
                multiple pattern placeholder readonly required rows size step)

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
    <div class="mb-4">
      <label for={@id} class="inline-flex cursor-pointer items-center gap-2.5 text-sm text-ink">
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
          class={[
            "size-4 cursor-pointer rounded border-line-strong bg-surface accent-accent",
            @class
          ]}
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-4">
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[field_classes(@errors), "select-field", @class]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.hint :if={@hint}>{@hint}</.hint>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-4">
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[field_classes(@errors), "min-h-24 py-2", @class]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.hint :if={@hint}>{@hint}</.hint>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[field_classes(@errors), @class]}
        {@rest}
      />
      <.hint :if={@hint}>{@hint}</.hint>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp field_classes(errors) do
    [
      "block h-9 w-full rounded-field border bg-surface px-3 text-sm text-ink shadow-low",
      "transition placeholder:text-ink-faint",
      "focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/40",
      "read-only:bg-surface-2 read-only:text-ink-muted",
      "disabled:cursor-not-allowed disabled:bg-surface-2 disabled:text-ink-muted",
      if(errors == [], do: "border-line-strong", else: "border-danger focus:ring-danger/30")
    ]
  end

  attr :for, :string, default: nil
  slot :inner_block, required: true

  defp label(assigns) do
    ~H"""
    <label for={@for} class="mb-1.5 block text-[13px] font-medium text-ink">
      {render_slot(@inner_block)}
    </label>
    """
  end

  slot :inner_block, required: true

  defp hint(assigns) do
    ~H"""
    <p class="mt-1.5 text-[13px] text-ink-muted">{render_slot(@inner_block)}</p>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-[13px] text-danger">
      <.icon name="hero-exclamation-circle-micro" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  ## Layout blocks

  @doc """
  Renders a page header: a title, an optional one-line description and a
  primary action slot.

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
    <header class={[
      "mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between",
      @class
    ]}>
      <div class="min-w-0">
        <h1 class="text-xl font-semibold tracking-tight text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  A bordered surface.
  """
  attr :class, :any, default: nil
  attr :padding, :boolean, default: true
  attr :rest, :global
  slot :inner_block, required: true
  slot :title
  slot :actions

  def card(assigns) do
    ~H"""
    <section
      class={["rounded-box border border-line bg-surface shadow-low", @class]}
      {@rest}
    >
      <div
        :if={@title != []}
        class="flex items-center justify-between gap-4 border-b border-line px-5 py-3.5"
      >
        <h2 class="text-sm font-semibold text-ink">{render_slot(@title)}</h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      <div class={@padding && "px-5 py-4"}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  A summary figure.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :navigate, :string, default: nil

  def stat(%{navigate: nil} = assigns) do
    ~H"""
    <div class="block rounded-box border border-line bg-surface px-5 py-4 shadow-low">
      <.stat_body label={@label} value={@value} hint={@hint} />
    </div>
    """
  end

  def stat(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="block rounded-box border border-line bg-surface px-5 py-4 shadow-low transition hover:border-line-strong hover:bg-surface-2"
    >
      <.stat_body label={@label} value={@value} hint={@hint} />
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil

  defp stat_body(assigns) do
    ~H"""
    <p class="text-[13px] font-medium text-ink-muted">{@label}</p>
    <p class="mt-1 text-2xl font-semibold tabular-nums tracking-tight text-ink">{@value}</p>
    <p :if={@hint} class="mt-1 text-[13px] text-ink-faint">{@hint}</p>
    """
  end

  @doc """
  An empty state with an icon, a title, a description and actions.
  """
  attr :icon, :string, default: "hero-key"
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "rounded-box border border-dashed border-line-strong bg-surface px-6 py-12 text-center",
      @class
    ]}>
      <div class="mx-auto flex size-12 items-center justify-center rounded-full bg-accent-soft text-accent-soft-ink">
        <.icon name={@icon} class="size-6" />
      </div>
      <h2 class="mt-4 text-base font-semibold text-ink">{@title}</h2>
      <div class="mx-auto mt-1.5 max-w-md text-sm text-ink-muted">{render_slot(@inner_block)}</div>
      <div :if={@actions != []} class="mt-6 flex justify-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  A small status label.
  """
  attr :color, :string, default: "neutral", values: ~w(neutral success warning danger accent)
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2 py-0.5",
      "text-xs font-medium",
      badge_classes(@color),
      @class
    ]}>
      <span :if={@color != "neutral"} class="size-1.5 rounded-full bg-current" aria-hidden="true" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_classes("neutral"), do: "border-line bg-surface-2 text-ink-muted"
  defp badge_classes("success"), do: "border-success/30 bg-success-soft text-success-soft-ink"
  defp badge_classes("warning"), do: "border-warn/40 bg-warn-soft text-warn-soft-ink"
  defp badge_classes("danger"), do: "border-danger/30 bg-danger-soft text-danger-soft-ink"
  defp badge_classes("accent"), do: "border-accent/40 bg-accent-soft text-accent-soft-ink"

  @doc """
  A block of preformatted text with a copy button.
  """
  attr :id, :string, required: true
  attr :code, :string, required: true
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def code_block(assigns) do
    ~H"""
    <div class={["overflow-hidden rounded-box border border-line bg-surface-2", @class]}>
      <div class="flex items-center justify-between gap-3 border-b border-line px-3 py-2">
        <span class="font-mono text-xs text-ink-muted">{@label}</span>
        <.copy_button id={"#{@id}-copy"} text={@code} />
      </div>
      <pre
        id={@id}
        class="overflow-x-auto px-4 py-3 font-mono text-[13px] leading-relaxed text-ink"
      ><code>{@code}</code></pre>
    </div>
    """
  end

  @doc """
  A short inline code span, for key ids and similar.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def mono(assigns) do
    ~H"""
    <code class={["rounded-md bg-surface-2 px-1.5 py-0.5 font-mono text-[13px] text-ink", @class]}>
      {render_slot(@inner_block)}
    </code>
    """
  end

  @doc """
  An inline notice.
  """
  attr :kind, :atom, default: :info, values: [:info, :warning, :danger]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div
      role="note"
      class={[
        "flex items-start gap-2.5 rounded-field border px-3.5 py-3 text-sm",
        @kind == :info && "border-line bg-surface-2 text-ink-muted",
        @kind == :warning && "border-warn/40 bg-warn-soft text-warn-soft-ink",
        @kind == :danger && "border-danger/30 bg-danger-soft text-danger-soft-ink",
        @class
      ]}
    >
      <.icon
        name={
          case @kind do
            :info -> "hero-information-circle-mini"
            :warning -> "hero-exclamation-triangle-mini"
            :danger -> "hero-exclamation-circle-mini"
          end
        }
        class="mt-0.5 size-4 shrink-0"
      />
      <div class="min-w-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  ## Tables

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
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
    <div class={["overflow-x-auto rounded-box border border-line bg-surface shadow-low", @class]}>
      <table class="w-full text-sm">
        <thead class="border-b border-line bg-surface-2/60 text-left">
          <tr>
            <th
              :for={col <- @col}
              class={[
                "px-4 py-2.5 text-xs font-medium uppercase tracking-wide text-ink-muted",
                col[:class]
              ]}
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="px-4 py-2.5">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}
          class="divide-y divide-line"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="transition hover:bg-surface-2/60"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={["px-4 py-3 align-middle text-ink", @row_click && "cursor-pointer", col[:class]]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 px-4 py-3 align-middle">
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

  @doc """
  Renders a data list.

      <.list>
        <:item title="Title">{@post.title}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="divide-y divide-line">
      <div :for={item <- @item} class="grid gap-1 py-3 sm:grid-cols-3 sm:gap-4">
        <dt class="text-sm font-medium text-ink-muted">{item.title}</dt>
        <dd class="text-sm text-ink sm:col-span-2">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  ## Modal

  @doc """
  Renders a modal. Render it conditionally (for example on a live action) and
  pass an `on_cancel` JS command, usually a patch back to the index.

      <.modal :if={@live_action == :new} id="new-key" on_cancel={JS.patch(~p"/hive/keys")} title="New access key">
        ...
        <:footer>
          <.button phx-click={JS.patch(~p"/hive/keys")}>Cancel</.button>
        </:footer>
      </.modal>
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  attr :dismissable, :boolean, default: true, doc: "close on escape, click outside and the X"
  attr :size, :string, default: "md", values: ~w(sm md lg)
  slot :inner_block, required: true
  slot :footer

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-50"
      role="dialog"
      aria-modal="true"
      aria-labelledby={@title && "#{@id}-title"}
      phx-mounted={show_modal(@id)}
      phx-remove={hide_modal(@id)}
      phx-window-keydown={@dismissable && @on_cancel}
      phx-key="escape"
    >
      <div id={"#{@id}-bg"} class="fixed inset-0 bg-overlay transition-opacity" aria-hidden="true" />
      <div class="fixed inset-0 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4 sm:p-6">
          <div
            id={"#{@id}-panel"}
            class={[
              "relative w-full rounded-box border border-line bg-surface shadow-pop",
              @size == "sm" && "max-w-sm",
              @size == "md" && "max-w-lg",
              @size == "lg" && "max-w-2xl"
            ]}
            phx-click-away={@dismissable && @on_cancel}
          >
            <div :if={@title || @dismissable} class="flex items-start justify-between gap-4 px-6 pt-5">
              <h2 :if={@title} id={"#{@id}-title"} class="text-base font-semibold text-ink">
                {@title}
              </h2>
              <button
                :if={@dismissable}
                type="button"
                phx-click={@on_cancel}
                class="-m-1.5 ml-auto rounded-md p-1.5 text-ink-faint transition hover:bg-surface-2 hover:text-ink"
                aria-label={gettext("Close")}
              >
                <.icon name="hero-x-mark-mini" class="size-5" />
              </button>
            </div>
            <div id={"#{@id}-content"} class="px-6 py-4 text-sm text-ink">
              {render_slot(@inner_block)}
            </div>
            <div
              :if={@footer != []}
              class="flex flex-col-reverse gap-2 border-t border-line px-6 py-4 sm:flex-row sm:justify-end"
            >
              {render_slot(@footer)}
            </div>
          </div>
        </div>
      </div>
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

  ## Formatting

  @doc "A short date: 12 Sep 2026."
  def short_date(nil), do: nil
  def short_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y")
  def short_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y")

  @doc "A short date and time in UTC: 12 Sep 2026, 14:03 UTC."
  def short_datetime(nil), do: nil
  def short_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y, %H:%M UTC")
  def short_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%-d %b %Y, %H:%M UTC")

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-out duration-150", "opacity-0 translate-y-1",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 translate-y-1"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 150,
      transition: {"transition-opacity ease-out duration-150", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-panel",
      time: 150,
      transition:
        {"transition-all ease-out duration-150", "opacity-0 translate-y-2 scale-[0.98]",
         "opacity-100 translate-y-0 scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      time: 150,
      transition: {"transition-opacity ease-in duration-150", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "##{id}-panel",
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0 scale-100",
         "opacity-0 translate-y-2 scale-[0.98]"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "block"}, time: 150)
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
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
