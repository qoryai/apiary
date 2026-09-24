defmodule Apiary.Policy.Export do
  @moduledoc """
  An effective policy as the text a node without a server is given (S7).

  The runner file, `~/.config/qory/runner.yaml`, holds the machine's policy inline as its
  `egress` section, which says a mode, the hosts allowed, the hosts denied and nothing
  else. Paths and credentials are said by a policy document, the contract's own format,
  given to one run with `qory run --policy <file>`; it narrows the machine's section and
  never widens it, so the two are exported together and agree.

  Every scalar is written as a JSON string, which YAML reads as it is, with the line
  breaks YAML knows and JSON does not (U+0085, U+2028, U+2029) escaped.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Policy.Effective

  @doc false
  def text(%Effective{} = effective) do
    narrowed = map_size(effective.paths) > 0 or effective.credentials != []

    %{
      runner_file: runner_file(effective),
      policy_file: if(narrowed, do: policy_file(effective)),
      notes: notes(effective, narrowed)
    }
  end

  defp runner_file(effective) do
    IO.iodata_to_binary([
      "# ~/.config/qory/runner.yaml\n",
      "egress:\n",
      egress(effective, "  ", false)
    ])
  end

  defp policy_file(effective) do
    IO.iodata_to_binary([
      "# ",
      gettext("A file outside the checkout, given with: %{command}",
        command: "qory run --policy <file>"
      ),
      "\n",
      "version: 1\n",
      "egress:\n",
      egress(effective, "  ", true),
      credentials(effective.credentials)
    ])
  end

  defp egress(effective, indent, with_paths) do
    [
      [indent, "mode: ", effective.mode, "\n"],
      case effective.allow do
        [] ->
          [indent, "allow: []\n"]

        allow ->
          [[indent, "allow:\n"], for(host <- allow, do: [indent, "  - ", quoted(host), "\n"])]
      end,
      case effective.deny do
        [] -> []
        deny -> [[indent, "deny:\n"], for(host <- deny, do: [indent, "  - ", quoted(host), "\n"])]
      end,
      if with_paths and map_size(effective.paths) > 0 do
        [
          [indent, "paths:\n"],
          for {host, paths} <- Enum.sort(effective.paths) do
            case paths do
              [] ->
                [indent, "  ", quoted(host), ": []\n"]

              paths ->
                [
                  [indent, "  ", quoted(host), ":\n"],
                  for(path <- paths, do: [indent, "    - ", quoted(path), "\n"])
                ]
            end
          end
        ]
      else
        []
      end
    ]
  end

  defp credentials([]), do: []

  defp credentials(credentials) do
    [
      "credentials:\n",
      for credential <- credentials do
        [
          ["  - name: ", quoted(credential.name), "\n"],
          if(credential[:argument],
            do: ["    argument: ", quoted(credential.argument), "\n"],
            else: []
          )
        ]
      end
    ]
  end

  defp notes(effective, narrowed) do
    List.flatten([
      if(effective.mode == "observe",
        do:
          gettext(
            "Under observe every connection is recorded and only a host in deny is denied; the allow list says what enforce would allow."
          ),
        else: []
      ),
      if(narrowed,
        do: [
          gettext(
            "The runner file's egress section says a mode and hosts only. The paths and the credentials are in the policy file, given to a run with --policy; it narrows the runner file's section."
          ),
          gettext(
            "Paths and credentials need a wall: without one the runner refuses to start the run."
          ),
          gettext(
            "A credential is named here and defined on the machine, in the credentials section of its runner file."
          )
        ],
        else: []
      )
    ])
  end

  # A JSON string, with the three characters JSON leaves raw and YAML reads as a line
  # break, which it would fold inside the quotes: U+2028 and U+2029 (escaped by
  # `:javascript_safe`) and U+0085. Everything else stays as it is: escaping every
  # character outside ASCII would write astral ones as surrogate pairs, which YAML's
  # `\u` does not read.
  defp quoted(text) do
    text |> Jason.encode!(escape: :javascript_safe) |> String.replace("\u0085", "\\u0085")
  end
end
