defmodule Apiary.SecretScan do
  @moduledoc """
  SecretScan finds secrets in a text: Qory Apiary's credentials, and the API keys and
  access tokens of the services a run uses most. `scan/1` returns where each secret is, by
  byte offset and length, and its kind; `identify/3` reads what a Qory Apiary credential
  belongs to. Neither keeps or logs a secret.

  Each kind is a prefix and a body of a fixed or a least length, the shortest that the
  issuer's format makes, and stands alone: no letter, digit, `_` or `-` right before it or
  right after it, so a longer word that contains a prefix (`task-…`, `sk-learn`) is none.

    * `access_key`: `qak_` and the 32-byte seed in base64url, 43 characters.
    * `run_key`: `qrk_`, the payload in base64url, `.`, and the 64-byte signature in
      base64url, 86 characters (`Apiary.Runs.RunKey`).
    * `enrolment_code`: `qecn_`, `qecp_`, `qecg_`, `qeci_` or `qecd_`, then 26 characters of
      Crockford base32, in either case and in groups split by `-`
      (`Apiary.AccessKeys.EnrolmentCode`).
    * `run_code`: `qecr_` and 26 characters, as an enrolment code.
    * `anthropic_api_key`: `sk-ant-` and 32 or more base64url characters. A key
      Anthropic makes, `sk-ant-api03-…`, is 108 characters.
    * `openai_api_key`: `sk-proj-`, `sk-svcacct-` or `sk-admin-` and 40 or more base64url
      characters, or a key of the first format, `sk-` and 48 letters and digits.
    * `github_token`: `ghp_`, `gho_`, `ghu_`, `ghs_` or `ghr_` and 36 or more letters and
      digits, or a fine-grained token, `github_pat_` and 82 or more letters, digits and `_`.
    * `gitlab_token`: `glpat-` and 20 or more base64url characters, with the `.`-separated
      parts that a token of the newer format ends with.

  A code of the enrolment-code or run-code form whose body is outside Crockford base32 (a
  `U`, for instance) is no code, and is left out.
  """

  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Repo
  alias Apiary.Runs.{Run, RunKey}

  import Ecto.Query

  @type kind ::
          :access_key
          | :run_key
          | :enrolment_code
          | :run_code
          | :anthropic_api_key
          | :openai_api_key
          | :github_token
          | :gitlab_token
  @type finding :: %{kind: kind, offset: non_neg_integer, length: pos_integer}

  # A byte mode regex: a text is any bytes, and offsets are byte offsets. The names sort
  # as `Regex.scan/3` returns the groups, by name.
  @secrets ~r/(?<![A-Za-z0-9_-])(?:(?<access_key>qak_[A-Za-z0-9_-]{43})|(?<run_key>qrk_[A-Za-z0-9_-]{20,1957}\.[A-Za-z0-9_-]{86})|(?<run_code>(?i:qecr_)(?:[0-9A-Za-z]-?){25}[0-9A-Za-z])|(?<enrolment_code>(?i:qec[npgid]_)(?:[0-9A-Za-z]-?){25}[0-9A-Za-z])|(?<anthropic_api_key>sk-ant-[A-Za-z0-9_-]{32,})|(?<openai_api_key>sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{40,}|sk-[A-Za-z0-9]{48})|(?<github_token>gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{82,})|(?<gitlab_token>glpat-[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+)*))(?![A-Za-z0-9_-])/
  @kinds [
    :access_key,
    :anthropic_api_key,
    :enrolment_code,
    :github_token,
    :gitlab_token,
    :openai_api_key,
    :run_code,
    :run_key
  ]

  # The characters a secret is made of, at the end of a text: a secret that a text cut
  # in two starts in this run.
  @token_end ~r/[A-Za-z0-9_.-]*\z/
  # The longest run of them kept for the next part of a text: longer than any secret of a
  # bounded kind.
  @carry_bytes 4096

  @doc "kinds/0 is every kind `scan/1` finds."
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc """
  scan/1 is every secret in `text`, in the order they appear, by byte offset and length.
  """
  @spec scan(binary) :: [finding]
  def scan(text) when is_binary(text) do
    @secrets
    |> Regex.scan(text, return: :index, capture: :all_names)
    |> Enum.flat_map(fn groups ->
      {kind, {offset, length}} =
        @kinds |> Enum.zip(groups) |> Enum.find(fn {_kind, {offset, _}} -> offset >= 0 end)

      if valid?(kind, binary_part(text, offset, length)),
        do: [%{kind: kind, offset: offset, length: length}],
        else: []
    end)
  end

  defp valid?(kind, value) when kind in [:enrolment_code, :run_code],
    do: normal_code(value) != :error

  defp valid?(_kind, _value), do: true

  @doc """
  carry/1 is the end of `text` that a secret cut off by the end may start in: its last
  run of the characters a secret is made of, at most #{@carry_bytes} bytes; an empty text
  when the run is longer, as no secret of a bounded kind starts that far back.
  """
  @spec carry(binary) :: binary
  def carry(text) when is_binary(text) do
    [{start, length}] = Regex.run(@token_end, text, return: :index)
    if length <= @carry_bytes, do: binary_part(text, start, length), else: ""
  end

  @doc """
  identify/3 is the public id of what `value`, a secret of `kind`, belongs to in the
  organisation `organisation_id`: the access key's id, `ak_`, for an access key; the
  run's id, `rn_`, for a run key or a run code; and the id of the node an enrolment code
  was made for. Nil when nothing of the organisation matches, and for any other kind.

  An access key matches the stored public half that its seed makes; a run key, once its
  signature checks, the run its payload names; a code, the stored SHA-256 of its normal
  form. Each match is one indexed read, the access key's by the organisation.
  """
  @spec identify(kind, binary, Ecto.UUID.t()) :: String.t() | nil
  def identify(:access_key, "qak_" <> seed, organisation_id) do
    with {:ok, <<_::binary-size(32)>> = seed} <- Base.url_decode64(seed, padding: false) do
      {public_key, _seed} = :crypto.generate_key(:eddsa, :ed25519, seed)

      Repo.one(
        from k in AccessKey,
          where: k.organisation_id == ^organisation_id and k.public_key == ^public_key,
          select: k.key_id,
          limit: 1
      )
    else
      _ -> nil
    end
  end

  def identify(:run_key, value, organisation_id) do
    case RunKey.verify(value) do
      {:ok, %{workspace: workspace, run_id: run_id}, _payload} ->
        Repo.one(
          from r in Run,
            join: w in Workspace,
            on: w.id == r.workspace_id,
            where: w.public_id == ^workspace and r.node_run_id == ^run_id,
            where: r.organisation_id == ^organisation_id,
            select: r.public_id,
            limit: 1
        )

      :error ->
        nil
    end
  end

  def identify(:run_code, value, organisation_id) do
    with {:ok, code} <- normal_code(value) do
      Repo.one(
        from r in Run,
          where: r.run_code_sha256 == ^EnrolmentCode.hash(code),
          where: r.organisation_id == ^organisation_id,
          select: r.public_id
      )
    else
      _ -> nil
    end
  end

  def identify(:enrolment_code, value, organisation_id) do
    with {:ok, code} <- normal_code(value) do
      Repo.one(
        from c in EnrolmentCode,
          join: n in Node,
          on: n.id == c.node_id,
          where: c.code_sha256 == ^EnrolmentCode.hash(code),
          where: c.organisation_id == ^organisation_id,
          select: n.public_id
      )
    else
      _ -> nil
    end
  end

  def identify(_kind, _value, _organisation_id), do: nil

  # A code in its normal form, as its SHA-256 was stored: a run code read as an enrolment
  # code is, with its prefix put back.
  defp normal_code(value) do
    run_prefix = EnrolmentCode.run_prefix()
    size = byte_size(run_prefix)

    case value do
      <<prefix::binary-size(^size), body::binary>> ->
        if String.downcase(prefix, :ascii) == run_prefix do
          with {:ok, normal} <- EnrolmentCode.normalise(EnrolmentCode.prefix(:node) <> body),
               do: {:ok, run_prefix <> binary_part(normal, size, byte_size(normal) - size)}
        else
          EnrolmentCode.normalise(value)
        end

      _shorter ->
        :error
    end
  end
end
