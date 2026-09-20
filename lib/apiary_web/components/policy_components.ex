defmodule ApiaryWeb.PolicyComponents do
  @moduledoc """
  The components of the security policy (`docs/design/brief-policy.md`, pd1 to pd7): the
  version pill and the version link, the mark of a rule, the source chip, the mode switch,
  the rule composer with its reading line, the rules table with provenance, the
  suggestions of the harness, the history of changes with its diff, and the document well.

  The pages under `/hive/policy` use all of them; the run page and the connections pages
  use the first four, so a version, a rule and where it came from look the same wherever
  a policy is named.

  Everything rendered here comes from `Apiary.Policy` or from a form: hosts, paths and
  names are only ever interpolated, never `raw/1`.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [icon: 1]

  ## pd1. Version pill and version link

  @doc """
  The version and digest, wherever a policy is named: page heads, history rows, the diff
  bar. `copy` adds the icon-only button that copies the full digest; `sm` is the 22 px
  pill of a history row, without shadow and without copy.
  """
  attr :id, :string, default: nil, doc: "required with `copy`: the copy button hangs on it"
  attr :version, :integer, default: nil, doc: "nil renders \"No version yet\""
  attr :digest, :string, default: nil, doc: "\"sha256=…\"; the first 12 hex characters show"
  attr :navigate, :string, default: nil, doc: "the version page"
  attr :copy, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :class, :any, default: nil

  def version_pill(%{version: nil} = assigns) do
    ~H"""
    <span class={["q-vpill", @size == "sm" && "q-vpill-sm", @class]}>
      <span class="q-vpill-dg">No version yet</span>
    </span>
    """
  end

  def version_pill(assigns) do
    ~H"""
    <span class={["q-vpill", @size == "sm" && "q-vpill-sm", @class]} title={@digest}>
      <.link :if={@navigate} navigate={@navigate} class="q-vpill-v">
        <span class="sr-only">Version </span>v{@version}
      </.link>
      <span :if={!@navigate} class="q-vpill-v"><span class="sr-only">Version </span>v{@version}</span>
      <span :if={@digest} class="q-vpill-dg">
        <i :if={@size == "md"}>sha256</i>{short_digest(@digest)}
      </span>
      <button
        :if={@copy && @size == "md" && @digest && @id}
        id={"#{@id}-copy"}
        type="button"
        phx-hook="CopyToClipboard"
        data-copy={@digest}
        class="copy-btn q-vpill-copy tooltip tooltip-left"
        data-tip="Copy the digest"
        aria-label="Copy the digest"
      >
        <span class="copy-idle"><.icon name="hero-clipboard-document-micro" class="size-3" /></span>
        <span class="copy-done"><.icon name="hero-check-micro" class="size-3" /></span>
        <span class="sr-only" aria-live="polite"></span>
      </button>
    </span>
    """
  end

  @doc """
  A version inside running text (a timeline head, a summary line, the run header): not a
  pill but a link, mono 600, underlined in the field line.
  """
  attr :version, :integer, required: true
  attr :navigate, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil

  def version_link(%{navigate: nil} = assigns) do
    ~H"""
    <span class={["q-ver q-ver-plain", @class]} title={@title}>v{@version}</span>
    """
  end

  def version_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["q-ver", @class]} title={@title}>v{@version}</.link>
    """
  end

  @doc "The first twelve hex characters of a `sha256=…` digest, as every page shows one."
  def short_digest("sha256=" <> hex), do: String.slice(hex, 0, 12)
  def short_digest(digest) when is_binary(digest), do: String.slice(digest, 0, 12)
  def short_digest(_digest), do: nil

  ## pd4. The mark of a rule

  @doc """
  The 18 px mark of a rule, in the vocabulary of a connection's decision mark: allow is
  the soft green check, deny the solid red barred circle, `pending` the dashed red outline
  of a host nothing has decided yet (a suggestion, a destination enforce would deny).
  """
  attr :action, :string, required: true, values: ~w(allow deny pending)
  attr :class, :any, default: nil

  def rule_mark(assigns) do
    ~H"""
    <span class={["q-mark", rule_mark_class(@action), @class]} title={rule_mark_word(@action)}>
      <.icon
        name={if @action == "allow", do: "hero-check-micro", else: "hero-no-symbol-micro"}
        class="size-3"
      />
      <span class="sr-only">{rule_mark_word(@action)}</span>
    </span>
    """
  end

  defp rule_mark_class("allow"), do: "q-mark-ok"
  defp rule_mark_class("deny"), do: "q-mark-no"
  defp rule_mark_class("pending"), do: "q-mark-pend"

  defp rule_mark_word("allow"), do: "Allow"
  defp rule_mark_word("deny"), do: "Deny"
  defp rule_mark_word("pending"), do: "Not allowed"

  ## pd5. Source chip

  @doc """
  Where a rule comes from: three shapes, three wordings, no status hue. `label` replaces
  the words where the same chip names a repository's policy ("Own rules", "Hive baseline")
  or marks a change the hive made ("hive").
  """
  attr :source, :atom, required: true, values: [:hive, :repository, :hive_locked]
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def source_chip(assigns) do
    ~H"""
    <span class={["q-src", source_class(@source), @class]}>
      <.icon :if={@source == :repository} name="hero-book-open-micro" class="size-3" />
      <.icon :if={@source == :hive_locked} name="hero-lock-closed-micro" class="size-3" />
      <svg
        :if={@source == :hive}
        viewBox="0 0 16 16"
        class="size-3"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="m8 2 5.2 3v6L8 14l-5.2-3V5z" />
      </svg>
      {@label || source_words(@source)}
    </span>
    """
  end

  defp source_class(:hive), do: nil
  defp source_class(:repository), do: "q-src-repo"
  defp source_class(:hive_locked), do: "q-src-lock"

  defp source_words(:hive), do: "Hive"
  defp source_words(:repository), do: "This repository"
  defp source_words(:hive_locked), do: "Hive, locked"
end
