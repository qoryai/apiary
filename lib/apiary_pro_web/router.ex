defmodule ApiaryProWeb.Router do
  @moduledoc """
  The edition's router: the core's routes (`ApiaryWeb.Routes`), with the edition's pages in
  the core's `live_session`s. The endpoint dispatches here once the edition names it
  (`ApiaryWeb.Edition.router/0`).

  Every page here is a LiveView of the edition: the core's pages link to them through the
  places the core gives the edition (`ApiaryWeb.Extension`, `ApiaryWeb.Nav.Entry`). The
  sign-up page is the one core path the edition serves with a separate page, since it offers
  kinds of organisation.
  """
  use ApiaryProWeb, :router

  import ApiaryWeb.Routes

  pipelines()
  public_routes()
  # The component storybook, in development and test only, as the core's router has it.
  storybook_routes()

  account_routes do
    # A new organisation, whose first owner the person is: the organisation switcher's New
    # organisation entry leads here, from any organisation, and a person in none reaches
    # it from their organisations page too.
    live "/users/organisations/new", ApiaryProWeb.UserLive.NewOrganisation, :new
  end

  # The edition's sign-up offers kinds of organisation: the edition's sign-up page at the
  # core's path.
  visitor_routes except: ["/users/register"] do
    live "/users/register", ApiaryProWeb.UserLive.Registration, :new
  end

  # The Instance level, the instance admins': its Organisations, with the creation of one,
  # the arbiter's transfer of an organisation's ownership and an organisation's features as
  # pages, and a change of kind, a purge and a suspension confirmed on the organisation's
  # row, by its id; its Accounts, with an account's suspension confirmed on its row. Each
  # page lets in the instance admins alone (`ApiaryProWeb.InstanceLive.Components`); their
  # paths are `ApiaryProWeb.InstanceLive.Paths`'. Before the organisations' routes, whose
  # `/:org` would take `/instance`.
  instance_routes do
    live "/instance/organisations", ApiaryProWeb.InstanceLive.Organisations, :index
    live "/instance/organisations/new", ApiaryProWeb.InstanceLive.Organisations, :new
    live "/instance/organisations/:id/kind", ApiaryProWeb.InstanceLive.Organisations, :kind
    live "/instance/organisations/:id/purge", ApiaryProWeb.InstanceLive.Organisations, :purge
    live "/instance/organisations/:id/suspend", ApiaryProWeb.InstanceLive.Organisations, :suspend

    live "/instance/organisations/:id/transfer",
         ApiaryProWeb.InstanceLive.Organisations,
         :transfer

    live "/instance/organisations/:id/features",
         ApiaryProWeb.InstanceLive.Organisations,
         :features

    live "/instance/accounts", ApiaryProWeb.InstanceLive.Accounts, :index
    live "/instance/accounts/:id/suspend", ApiaryProWeb.InstanceLive.Accounts, :suspend
  end

  organisation_routes do
    scope "/:org" do
      # The workspaces of one member, which an owner or an admin adds them to or removes
      # them from.
      live "/settings/people/:id/workspaces", ApiaryProWeb.MemberLive.Workspaces, :index

      # The organisation's ownership, a section of its settings: its operator, and offers of
      # its ownership. Offering it to an operator is a page of it; withdrawing the offer, and
      # a client's leaving its operator, are confirmed in place on it.
      live "/settings/ownership", ApiaryProWeb.SettingsLive.Ownership, :index
      live "/settings/ownership/transfer", ApiaryProWeb.SettingsLive.Ownership, :transfer
      live "/settings/ownership/withdraw", ApiaryProWeb.SettingsLive.Ownership, :withdraw
      live "/settings/ownership/leave", ApiaryProWeb.SettingsLive.Ownership, :leave

      # The organisation's secrets, the Secrets tab of its settings' Secrets and
      # variables, as a workspace's are: each form a page and each deletion confirmed on
      # its row, each at a separate path. A secret is named by its public id (`sec_…`), a
      # value by its value id; the one value without a value id is the secret's
      # `change-value`.
      live "/settings/secrets", ApiaryProWeb.SettingsLive.Secrets, :index
      live "/settings/secrets/new", ApiaryProWeb.SettingsLive.Secrets, :new_secret
      live "/settings/secrets/:id/edit", ApiaryProWeb.SettingsLive.Secrets, :edit_secret
      live "/settings/secrets/:id/add-value", ApiaryProWeb.SettingsLive.Secrets, :add_value

      live "/settings/secrets/:id/change-value",
           ApiaryProWeb.SettingsLive.Secrets,
           :change_value

      live "/settings/secrets/:id/values/:value_id/change",
           ApiaryProWeb.SettingsLive.Secrets,
           :change_value

      live "/settings/secrets/:id/values/:value_id/rename",
           ApiaryProWeb.SettingsLive.Secrets,
           :rename_value

      live "/settings/secrets/:id/values/:value_id/delete",
           ApiaryProWeb.SettingsLive.Secrets,
           :delete_value

      live "/settings/secrets/:id/delete", ApiaryProWeb.SettingsLive.Secrets, :delete_secret

      # The organisation's variables, the Variables tab of its settings' Secrets and
      # variables: New variable and Change value are pages of it; a lock, an unlock and a
      # deletion are confirmed on the row.
      live "/settings/variables", ApiaryProWeb.SettingsLive.Variables, :index
      live "/settings/variables/new", ApiaryProWeb.SettingsLive.Variables, :new
      live "/settings/variables/:id/change", ApiaryProWeb.SettingsLive.Variables, :change
      live "/settings/variables/:id/lock", ApiaryProWeb.SettingsLive.Variables, :lock
      live "/settings/variables/:id/unlock", ApiaryProWeb.SettingsLive.Variables, :unlock
      live "/settings/variables/:id/delete", ApiaryProWeb.SettingsLive.Variables, :delete

      # The organisation's policy, the level above its workspaces': its rules and its two
      # settings, its workspaces under it, and its history; and the pages of its rule
      # form, New rule and Edit rule.
      live "/policy", ApiaryProWeb.PolicyLive.Organisation, :rules
      live "/policy/rules/new", ApiaryProWeb.PolicyLive.Organisation, :new_rule
      live "/policy/rules/:id/edit", ApiaryProWeb.PolicyLive.Organisation, :edit_rule
      live "/policy/workspaces", ApiaryProWeb.PolicyLive.Organisation, :workspaces
      live "/policy/history", ApiaryProWeb.PolicyLive.Organisation, :history
      # A client's policy requests from its operator, which whoever writes its policy
      # accepts or declines.
      live "/policy-requests", ApiaryProWeb.PolicyRequestLive.Index, :index
      live "/policy-requests/:id", ApiaryProWeb.PolicyRequestLive.Index, :show
      live "/policy-requests/:id/decline", ApiaryProWeb.PolicyRequestLive.Index, :decline
      # An operator's clients, and as pages of them the creation of one, the invitation of
      # a client's first owner and its features; its drop and its deletion are confirmed
      # on its row, and the acceptance of an organisation offered to it on the offer's.
      live "/clients", ApiaryProWeb.ClientLive.Index, :index
      live "/clients/new", ApiaryProWeb.ClientLive.Index, :new
      # The operator's requests for changes to its clients' security policy, and as a page
      # of them the writing of one.
      live "/clients/requests", ApiaryProWeb.ClientLive.Requests, :index
      live "/clients/requests/new", ApiaryProWeb.ClientLive.Requests, :new
      live "/clients/requests/:id", ApiaryProWeb.ClientLive.Requests, :show
      live "/clients/requests/:id/withdraw", ApiaryProWeb.ClientLive.Requests, :withdraw
      live "/clients/:id/owner", ApiaryProWeb.ClientLive.Index, :invite_owner
      # Not found while the operator does not own its clients, as /owner is while it does.
      live "/clients/:id/admin", ApiaryProWeb.ClientLive.Index, :invite_admin
      live "/clients/:id/features", ApiaryProWeb.ClientLive.Index, :features
      live "/clients/:id/drop", ApiaryProWeb.ClientLive.Index, :drop
      live "/clients/:id/delete", ApiaryProWeb.ClientLive.Index, :delete
      live "/clients/offers/:id/accept", ApiaryProWeb.ClientLive.Index, :accept_offer
      # The Instance's former addresses, under the instance organisation, which lead
      # to where the Instance is now.
      get "/instance", ApiaryProWeb.InstanceRedirectController, :show
      get "/instance/new", ApiaryProWeb.InstanceRedirectController, :show
      get "/instance/accounts", ApiaryProWeb.InstanceRedirectController, :show
      get "/instance/accounts/:id/suspend", ApiaryProWeb.InstanceRedirectController, :show
      get "/instance/:id/:act", ApiaryProWeb.InstanceRedirectController, :show
    end
  end
end
