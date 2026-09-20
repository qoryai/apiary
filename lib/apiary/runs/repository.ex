defmodule Apiary.Runs.Repository do
  @moduledoc """
  A repository the hive's runs have worked in, created on first sight from a
  run's `forge` and `repository` labels. Unique per hive on forge and path.
  """
  use Ecto.Schema

  @label_max 256
  # C0 and DEL, C1 (U+0085, the next line, among them), and the line and paragraph
  # separators: what ends a line somewhere, in a log, a YAML comment or a terminal.
  @control ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u

  @doc "The most bytes a forge or a repository label has."
  def label_max, do: @label_max

  @doc """
  A `forge` or `repository` label as one that can name a repository, or nil: a string of
  valid UTF-8, not empty, at most #{@label_max} bytes, with no control character (C0,
  DEL, C1 with U+0085, U+2028, U+2029). A label is a runner's word. One that fails this
  is neither cleaned nor cut, since either would file the run under a repository it did
  not name: the run is kept, with its labels as sent, and belongs to no repository. The
  projector and the wire (`Apiary.Policy.Serving`) both ask here, so they always pick the
  same repository, or none.
  """
  @spec label(term) :: String.t() | nil
  def label(label) when is_binary(label) and label != "" and byte_size(label) <= @label_max do
    if String.valid?(label) and not Regex.match?(@control, label), do: label
  end

  def label(_label), do: nil

  @typedoc "A repository the hive's runs named."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "repositories" do
    field :forge, :string
    field :path, :string
    field :first_seen_at, :utc_datetime_usec
    # The repository's own mode of the security policy; nil follows the hive's. Changed
    # through `Apiary.Policy.set_mode/3`.
    field :egress_mode, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    has_many :runs, Apiary.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end
end
