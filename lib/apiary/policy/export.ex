defmodule Apiary.Policy.Export do
  @moduledoc """
  An effective policy as the text a node without a server is given (S7).

  The runner file, `~/.config/qory/runner.yaml`, holds the machine's policy inline as its
  `egress` section, which says a mode and the hosts allowed and nothing else. Paths and
  credentials are said by a policy document, the contract's own format, given to one run
  with `qory run --policy <file>`; it narrows the machine's section and never widens it,
  so the two are exported together and agree.

  Every scalar is written as a JSON string, which YAML reads as it is.
  """

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
      "# A file outside the checkout, given with: qory run --policy <file>\n",
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
          "Under observe every connection is recorded and none is denied; the list says what enforce would allow.",
        else: []
      ),
      if(narrowed,
        do: [
          "The runner file's egress section says a mode and hosts only. The paths and the credentials are in the policy file, given to a run with --policy; it narrows the runner file's section.",
          "Paths and credentials need a wall: without one the runner refuses to start the run.",
          "A credential is named here and defined on the machine, in the credentials section of its runner file."
        ],
        else: []
      )
    ])
  end

  defp quoted(text), do: Jason.encode!(text)
end
