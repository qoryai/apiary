defmodule Apiary.SecretScanTest do
  # The secrets `Apiary.SecretScan` finds: each kind at its least length and the near
  # misses beside it, offsets in bytes, the end of a text carried to the next part with
  # the context before it, and
  # what a Qory Apiary credential belongs to, in its organisation alone.
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures, only: [gateway_run_attrs: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{AccessKeys, SecretScan}
  alias Apiary.AccessKeys.EnrolmentCode
  alias Apiary.Runs.{Run, RunKey}

  @b64 "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
  @alnum48 "T3BlbkFJabcdefghijklmnopqrstuvwxyzABCDEFGHIJ0123"

  defp kinds(text), do: text |> SecretScan.scan() |> Enum.map(& &1.kind)

  defp found(text) do
    for %{offset: offset, length: length} <- SecretScan.scan(text),
        do: binary_part(text, offset, length)
  end

  describe "scan/1" do
    test "finds each kind at the least length its format has" do
      secrets = %{
        access_key: "qak_" <> @b64,
        run_key: "qrk_" <> String.duplicate("e", 20) <> "." <> String.duplicate("s", 86),
        enrolment_code: "qecn_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A",
        run_code: "qecr_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A",
        anthropic_api_key: "sk-ant-api03-" <> String.duplicate("a", 32),
        openai_api_key: "sk-proj-" <> String.duplicate("b", 40),
        github_token: "ghp_" <> String.duplicate("c", 36),
        gitlab_token: "glpat-" <> String.duplicate("d", 20)
      }

      assert Map.keys(secrets) |> Enum.sort() == Enum.sort(SecretScan.kinds())

      for {kind, secret} <- secrets do
        text = "export TOKEN=#{secret}\n"
        assert [%{kind: ^kind, offset: 13, length: length}] = SecretScan.scan(text), secret
        assert length == byte_size(secret)
      end
    end

    test "finds the other formats of each issuer" do
      for {kind, secret} <- [
            anthropic_api_key: "sk-ant-api03-" <> String.duplicate("x", 93) <> "AA",
            anthropic_api_key: "sk-ant-admin01-" <> String.duplicate("x", 93) <> "AA",
            anthropic_api_key: "sk-ant-oat01-" <> String.duplicate("x", 93) <> "AA",
            openai_api_key: "sk-" <> @alnum48,
            openai_api_key: "sk-svcacct-" <> String.duplicate("q", 40),
            openai_api_key: "sk-admin-" <> String.duplicate("q", 40),
            github_token: "gho_" <> String.duplicate("1", 36),
            github_token: "ghu_" <> String.duplicate("1", 36),
            github_token: "ghs_" <> String.duplicate("1", 36),
            github_token: "ghr_" <> String.duplicate("1", 36),
            github_token:
              "github_pat_" <> String.duplicate("A", 22) <> "_" <> String.duplicate("b", 59),
            gitlab_token: "glpat-" <> String.duplicate("e", 27) <> ".01.0w1x2y3z4",
            enrolment_code: "QECP_7k3m-9p2q-4r6s-8t0v-1w5x-3y9z-2a",
            enrolment_code: "qecd_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A",
            enrolment_code: "qeci_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A",
            enrolment_code: "qecg_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A"
          ] do
        assert kinds("key: #{secret}.") == [kind], secret
        assert found("key: #{secret}.") == [secret], secret
      end
    end

    test "finds no near miss" do
      near_misses = [
        "pip install sk-learn scikit-learn",
        "sk-" <> String.slice(@alnum48, 0, 47),
        "sk-" <> @alnum48 <> "9",
        "sk-ant-placeholder",
        "sk-ant-" <> String.duplicate("a", 31),
        "sk-ant-" <> String.duplicate("a", 40),
        "sk-ant-api03-" <> String.duplicate("a", 31),
        "xqak_" <> @b64,
        "helpdesk-admin-service-account-token-production-eu-west-1-7f9c8d",
        "kiosk-admin-console-deployment-5d8f7c9b6-abcde-fghij-klmno",
        "feature/task-proj-management-dashboard-frontend-rewrite-v2",
        "helpdesk-svcacct-reader-binding-for-namespace-production-eu",
        "flask-ant-colony-simulation-backend-service-v3",
        "my-glpat-rotation-script-for-ci-jobs",
        "my_glpat-rotation-script-for-ci-jobs",
        "project_sk-proj-management-dashboard-frontend",
        "project_sk-proj-management-dashboard-frontend-build-and-release",
        "deploy_sk-ant-admin01-rotation-script-for-production-jobs",
        "sk-proj-" <> String.duplicate("b", 39),
        "task-" <> @alnum48,
        "risk-" <> @alnum48,
        "ghp_" <> String.duplicate("c", 35),
        "github_pat_" <> String.duplicate("A", 81),
        "glpat-" <> String.duplicate("d", 19),
        "qak_" <> String.slice(@b64, 0, 42),
        "qak_" <> @b64 <> "x",
        "qrk_" <> String.duplicate("e", 20) <> "." <> String.duplicate("s", 85),
        "qecn_7K3M9P2Q4R6S8T0V1W5X3Y9Z2",
        "qecn_7K3M9P2Q4R6S8T0V1W5X3Y9Z2AB",
        # U is outside Crockford base32.
        "qecn_7K3M9P2Q4R6S8T0V1W5X3Y9Z2U",
        "qecx_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A",
        "light_" <> String.duplicate("c", 40),
        "ghx_" <> String.duplicate("c", 36)
      ]

      for text <- near_misses, do: assert(SecretScan.scan(text) == [], text)
    end

    test "finds a secret after a colour code, an escape, a URL encoding, or `_` before `…_`" do
      ghp = "ghp_" <> String.duplicate("c", 36)
      ant = "sk-ant-api03-" <> String.duplicate("x", 93) <> "AA"

      for {text, secret} <- [
            {"\e[32m#{ghp}\e[0m\n", ghp},
            {~s({"log":"done\\n#{ant}"}), ant},
            {"https://ci.example/?token%3D#{ghp}&x=1", ghp},
            {"Authorization: Bearer%20#{ant}", ant},
            {"MY_TOKEN_#{ghp}", ghp},
            {"MY_KEY_qak_" <> @b64, "qak_" <> @b64},
            {"a\\t#{ant}", ant},
            {"XQAK_" <> "\e[1;32m" <> "qak_" <> @b64, "qak_" <> @b64}
          ] do
        assert found(text) == [secret], text
      end

      # The first OpenAI format's short prefix still needs a separator before it.
      assert found("task-" <> @alnum48) == []
      assert found("key=sk-" <> @alnum48) == ["sk-" <> @alnum48]
    end

    test "finds no sk-None- key, a format OpenAI does not document" do
      assert SecretScan.scan("sk-None-" <> String.duplicate("q", 48)) == []
    end

    test "returns byte offsets in text that is not UTF-8, and each secret in order" do
      access_key = "qak_" <> @b64
      gitlab = "glpat-" <> String.duplicate("d", 20)
      text = <<0xFF, "é ", access_key::binary, " and ", gitlab::binary>>

      assert [
               %{kind: :access_key, offset: 4, length: 47},
               %{kind: :gitlab_token, offset: 56, length: 26}
             ] = SecretScan.scan(text)
    end
  end

  describe "carry/1" do
    test "is the last run of a secret's characters, and nothing past 4096 bytes" do
      assert SecretScan.carry("line one\nkey qak_AQID") == "qak_AQID"
      assert SecretScan.carry("ends with a space ") == ""
      assert SecretScan.carry("x" <> String.duplicate("a", 4096)) == ""
      assert SecretScan.carry(" " <> String.duplicate("a", 4096)) == String.duplicate("a", 4096)
    end

    test "keeps the context a secret may follow whole, or as far as the end cut it" do
      for {text, end_} <- [
            {"done \e[32m", "\e[32m"},
            {"done \e[1;32m", "\e[1;32m"},
            {"done \e[1;32mghp_cc", "\e[1;32mghp_cc"},
            {"done \e[1;", "\e[1;"},
            {"done \e[", "\e["},
            {"done \e", "\e"},
            {~S(done\n), ~S(\n)},
            {"token%3D", "%3D"},
            {"token%", "%"},
            {"done [32m", "32m"},
            {"done 1;32m", "32m"}
          ] do
        assert SecretScan.carry(text) == end_, inspect(text)
      end
    end

    test "with what follows, finds a secret after a context, wherever the end cuts" do
      ghp = "ghp_" <> String.duplicate("c", 36)

      for context <- ["done \e[32m", "done \e[1;32m", ~S(log":"done\n), "q=token%3D"] do
        text = context <> ghp <> " end"

        # Each cut before the secret's end; a secret that ends the head is found in it.
        for cut <- 0..(byte_size(context) + byte_size(ghp) - 1) do
          {head, rest} =
            {binary_part(text, 0, cut), binary_part(text, cut, byte_size(text) - cut)}

          assert found(SecretScan.carry(head) <> rest) == [ghp], inspect({head, rest})
        end
      end
    end
  end

  describe "identify/3" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      %{scope: scope, other: other}
    end

    test "an access key is its key's id, by the public half its seed makes", ctx do
      %{access_key: key, secret: seed} = access_key_fixture(ctx.scope)
      secret = "qak_" <> Base.url_encode64(seed, padding: false)

      assert SecretScan.identify(:access_key, secret, ctx.scope.organisation.id) == key.key_id
      assert key.key_id =~ ~r/\Aak_/
      assert SecretScan.identify(:access_key, secret, ctx.other.organisation.id) == nil
      assert SecretScan.identify(:access_key, "qak_" <> @b64, ctx.scope.organisation.id) == nil
    end

    test "an enrolment code is its node's id, in any case and grouping", ctx do
      node = node_fixture(ctx.scope)
      {:ok, _row, code} = AccessKeys.create_enrolment_code(ctx.scope, node, %{})
      "qecn_" <> body = code

      typed =
        "QECN_" <>
          (body
           |> String.downcase()
           |> String.graphemes()
           |> Enum.chunk_every(4)
           |> Enum.join("-"))

      assert [%{kind: :enrolment_code}] = SecretScan.scan(typed)

      assert SecretScan.identify(:enrolment_code, code, ctx.scope.organisation.id) ==
               node.public_id

      assert SecretScan.identify(:enrolment_code, typed, ctx.scope.organisation.id) ==
               node.public_id

      assert SecretScan.identify(:enrolment_code, code, ctx.other.organisation.id) == nil
    end

    test "a run code and a run key are their run's id", ctx do
      code = EnrolmentCode.generate(:run)

      run =
        run_fixture(
          ctx.scope,
          Map.merge(gateway_run_attrs(DateTime.utc_now()), %{
            public_id: Run.new_public_id(),
            gateway_id: gateway_fixture(ctx.scope).id,
            run_code_sha256: EnrolmentCode.hash(code),
            run_code_expires_at: DateTime.utc_now(),
            run_code_grant: %{},
            run_code_public_key: <<0::256>>
          })
        )

      assert SecretScan.identify(:run_code, code, ctx.scope.organisation.id) == run.public_id

      assert SecretScan.identify(:run_code, String.downcase(code), ctx.scope.organisation.id) ==
               run.public_id

      assert SecretScan.identify(:run_code, code, ctx.other.organisation.id) == nil

      now = DateTime.utc_now()

      {:ok, run_key, _payload} =
        RunKey.issue(%{
          run_id: run.node_run_id,
          workspace: ctx.scope.workspace.public_id,
          node_id: "np_0000000000000000",
          gateway: "ng_0000000000000000",
          gateway_url: "https://gateway.example:8443",
          gateway_public_keys: [:crypto.strong_rand_bytes(32)],
          instance_id: "i_build-01",
          issued: now,
          attach_by: DateTime.add(now, 600, :second)
        })

      assert [%{kind: :run_key}] = SecretScan.scan("key #{run_key} end")
      assert SecretScan.identify(:run_key, run_key, ctx.scope.organisation.id) == run.public_id
      assert SecretScan.identify(:run_key, run_key, ctx.other.organisation.id) == nil

      [payload, _signature] = String.split(run_key, ".")
      forged = payload <> "." <> String.duplicate("A", 86)
      assert SecretScan.identify(:run_key, forged, ctx.scope.organisation.id) == nil
    end

    test "is nil for any other kind", ctx do
      assert SecretScan.identify(
               :github_token,
               "ghp_" <> String.duplicate("c", 36),
               ctx.scope.organisation.id
             ) ==
               nil
    end
  end
end
