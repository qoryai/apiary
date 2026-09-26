defmodule Apiary.Runs.Target do
  @moduledoc """
  What the workspace's runs change, in the system it lives in: created on first sight from
  a run's labels, which the workspace's domain reads (`Apiary.Lingo.Domain`). Unique per
  workspace on system and path. The software domain calls a target a repository and its
  system a forge.
  """
  use Ecto.Schema

  @label_max 256
  # C0 and DEL, C1 (U+0085, the next line, among them), and the line and paragraph
  # separators: what ends a line somewhere, in a log, a YAML comment or a terminal.
  @control ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u

  @doc "The most bytes a label that names a system or a path has."
  def label_max, do: @label_max

  @doc """
  A label as one that can name a target's system or path, or nil: a string of valid
  UTF-8, not empty, at most #{@label_max} bytes, with no control character (C0, DEL, C1
  with U+0085, U+2028, U+2029). A label is a runner's word. One that fails this is
  neither cleaned nor cut, since either would file the run under a target it did not
  name: the run is kept, with its labels as sent, and belongs to no target. Every domain's
  labelling rule asks here, and the projector and the wire (`Apiary.Policy.Serving`)
  both ask the domain, so they always pick the same target, or none.
  """
  @spec label(term) :: String.t() | nil
  def label(label) when is_binary(label) and label != "" and byte_size(label) <= @label_max do
    if String.valid?(label) and not Regex.match?(@control, label), do: label
  end

  def label(_label), do: nil

  @typedoc "A target the workspace's runs named."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "targets" do
    field :system, :string
    field :path, :string
    field :first_seen_at, :utc_datetime_usec
    # The target's own mode of the security policy; nil follows the workspace's. Changed
    # through `Apiary.Policy.set_mode/3`.
    field :egress_mode, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    has_many :runs, Apiary.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end
end
