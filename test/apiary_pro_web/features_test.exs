defmodule ApiaryProWeb.FeaturesRoutesTest do
  # The edition's router, the core's routes with the edition's pages, held to the instance's
  # features (`ApiaryWeb.RoutesFeaturesCase`): every route declares its feature, or is one
  # every instance has, the core's or the edition's pages below.
  use ApiaryWeb.RoutesFeaturesCase,
    async: true,
    router: ApiaryProWeb.Router,
    # The edition's pages every instance has: the Instance's Organisations and Accounts, and their
    # former addresses, an organisation's ownership, a member's
    # workspaces, a new organisation of the person's own, and the sign-up that offers
    # kinds.
    always: [
      ApiaryProWeb.InstanceLive.Organisations,
      ApiaryProWeb.InstanceLive.Accounts,
      ApiaryProWeb.InstanceRedirectController,
      ApiaryProWeb.SettingsLive.Ownership,
      ApiaryProWeb.MemberLive.Workspaces,
      ApiaryProWeb.UserLive.NewOrganisation,
      ApiaryProWeb.UserLive.Registration
    ]

  alias ApiaryWeb.RoutesFeaturesCase

  test "the organisation's policy belongs to organisation_policy" do
    routes = RoutesFeaturesCase.routes(ApiaryProWeb.Router)

    policy =
      for {_verb, "/:org/policy" <> rest, module} <- routes,
          rest == "" or String.starts_with?(rest, "/"),
          do: {rest, module}

    assert Enum.sort(Enum.map(policy, &elem(&1, 0))) ==
             ["", "/history", "/rules/:id/edit", "/rules/new", "/workspaces"]

    for {_rest, module} <- policy do
      assert module == ApiaryProWeb.PolicyLive.Organisation
      assert module.__feature__() == :organisation_policy
    end
  end

  test "the organisation's variables belong to organisation_variables, which needs secrets" do
    variables =
      for {_verb, "/:org/settings/variables" <> _, module} <-
            RoutesFeaturesCase.routes(ApiaryProWeb.Router),
          do: module

    assert variables != []

    for module <- variables do
      assert module.__feature__() == :organisation_variables, inspect(module)
    end

    assert :secrets in Apiary.Features.needs(:organisation_variables)
  end

  test "an operator's clients belong to managed_organisations, their policy requests to security" do
    routes = RoutesFeaturesCase.routes(ApiaryProWeb.Router)

    clients = for {_verb, "/:org/clients" <> rest, module} <- routes, do: {rest, module}
    assert clients != []

    for {rest, module} <- clients do
      if String.starts_with?(rest, "/requests"),
        do: assert(module.__feature__() == :security),
        else: assert(module.__feature__() == :managed_organisations)
    end

    requests = for {_verb, "/:org/policy-requests" <> _, module} <- routes, do: module
    assert requests != []

    for module <- requests do
      assert module.__feature__() == :security
    end
  end
end
