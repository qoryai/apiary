defmodule ApiaryWeb.NodeComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Apiary.Nodes.Node
  alias ApiaryWeb.NodeComponents

  @server "https://apiary.example.com"
  @code Apiary.AccessKeys.EnrolmentCode.prefix(:node) <> "0123456789ABCDEFGHJKMNPQRS.fingerprint"

  describe "enrol_command/3" do
    test "is qory's enrol, the server's address and the code, without a gateway" do
      assert NodeComponents.enrol_command(@server, @code) ==
               "qory access-key enrol https://apiary.example.com #{@code}"

      assert NodeComponents.enrol_command(@server, @code, via: nil) ==
               NodeComponents.enrol_command(@server, @code)

      assert NodeComponents.enrol_command(@server, @code, replace: true) ==
               "qory access-key enrol --replace https://apiary.example.com #{@code}"
    end

    test "carries --via and the gateway's URL before the server's address, as qory takes it" do
      assert NodeComponents.enrol_command(@server, @code, via: "https://edge.example.com") ==
               "qory access-key enrol --via https://edge.example.com https://apiary.example.com #{@code}"

      assert NodeComponents.enrol_command(@server, @code,
               replace: true,
               via: "https://edge.example.com"
             ) ==
               "qory access-key enrol --replace --via https://edge.example.com https://apiary.example.com #{@code}"
    end
  end

  describe "the command's words in a shell" do
    # What a POSIX shell makes of `command`: its words, each as the program receives it.
    defp words_in_shell(command) do
      {out, 0} =
        System.cmd("sh", ["-c", ~s(for w in #{command}; do printf '%s\\n' "$w"; done)],
          cd: System.tmp_dir!()
        )

      String.split(out, "\n", trim: true)
    end

    test "a gateway URL a shell would act on is one single-quoted word" do
      # The review's example, as words only: never handed to a shell here.
      assert NodeComponents.enrol_command(@server, @code,
               via: "https://edge.example.com;rm$IFS-rf$IFS~"
             ) ==
               "qory access-key enrol --via 'https://edge.example.com;rm$IFS-rf$IFS~' https://apiary.example.com #{@code}"

      # Harmless payloads, read back by a shell: each is one word, and nothing of it runs.
      for url <- [
            "https://edge.example.com;echo$IFS-ran",
            "https://edge.example.com/$(echo${IFS}ran)",
            "https://edge.example.com/it's&x=1",
            "https://[2001:db8::1]:8443"
          ] do
        command = NodeComponents.enrol_command(@server, @code, via: url)
        quoted = NodeComponents.shell_word(url)
        assert String.starts_with?(quoted, "'") and String.ends_with?(quoted, "'")

        assert command ==
                 "qory access-key enrol --via #{quoted} https://apiary.example.com #{@code}"

        # The shell reads it back as the URL, whole, and runs nothing of it.
        assert command |> String.replace_prefix("qory ", "") |> words_in_shell() ==
                 ["access-key", "enrol", "--via", url, @server, @code]
      end

      assert NodeComponents.shell_word("https://edge.example.com/it's") ==
               ~S('https://edge.example.com/it'\''s')
    end

    test "a plain URL, a URL with a port or a path, and a code are unchanged" do
      for word <- [
            "https://edge.example.com",
            "https://edge.example.com:8443/relay/~gw",
            "http://localhost:4100",
            @code
          ],
          do: assert(NodeComponents.shell_word(word) == word)

      # A leading ~ is a shell's home directory, and an empty value no word at all.
      assert NodeComponents.shell_word("~edge") == "'~edge'"
      assert NodeComponents.shell_word("") == "''"
    end

    test "the server's address is quoted by the same rule" do
      assert NodeComponents.enrol_command("https://apiary.example.com/a b", @code) ==
               "qory access-key enrol 'https://apiary.example.com/a b' #{@code}"
    end
  end

  describe "via_ca_line/1" do
    test "names --via-ca-file for a gateway, and is nothing without one" do
      gateway = %Node{kind: :gateway, name: "edge-01", url: "https://edge.example.com"}
      assigns = %{gateway: gateway}

      html = rendered_to_string(~H|<NodeComponents.via_ca_line id="ca" gateway={@gateway} />|)
      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.text() |> String.split() |> Enum.join(" ") ==
               "If edge-01's certificate is signed by a private certificate authority, add --via-ca-file and that authority's PEM file."

      assert doc |> LazyHTML.query("#ca .font-mono") |> LazyHTML.text() == "--via-ca-file"

      assigns = %{gateway: nil}

      assert rendered_to_string(~H|<NodeComponents.via_ca_line id="ca" gateway={@gateway} />|)
             |> String.trim() == ""
    end
  end
end
