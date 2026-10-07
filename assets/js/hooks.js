// The console's LiveView hooks, the external ones, each under hooks/: app.js registers
// them beside the colocated hooks of its application, and an edition's bundle imports
// this collection to register the same ones beside its own. `autoDismiss` is the toasts'
// timer, which app.js also runs for a page a controller rendered.
import {CopyToClipboard} from "./hooks/copy_to_clipboard"
import {Menu} from "./hooks/menu"
import {NavDrawer} from "./hooks/nav_drawer"
import {Switcher} from "./hooks/switcher"
import {Palette} from "./hooks/palette"
import {Toast, autoDismiss} from "./hooks/toast"
import {Ticker} from "./hooks/ticker"
import {RunList} from "./hooks/runs"
import {LiveEnd} from "./hooks/live_end"
import {TimelineKeys} from "./hooks/timeline_keys"
import {Terminal} from "./hooks/terminal"
import {FocusOn} from "./hooks/focus_on"
import {PolicyPage, RuleComposer, ChangeRow} from "./hooks/policy"
import {RulePanel} from "./hooks/rule_panel"
import {HostSuggest} from "./hooks/host_suggest"
import {DaysChart, OverviewPage} from "./hooks/overview"
import {FamilyBoxes} from "./hooks/family_boxes"
import {SecretValues} from "./hooks/secret_values"

export {autoDismiss}

export const hooks = {
  CopyToClipboard,
  Menu,
  NavDrawer,
  Switcher,
  Palette,
  Toast,
  Ticker,
  RunList,
  LiveEnd,
  TimelineKeys,
  Terminal,
  FocusOn,
  RulePanel,
  HostSuggest,
  PolicyPage,
  RuleComposer,
  ChangeRow,
  DaysChart,
  OverviewPage,
  FamilyBoxes,
  SecretValues,
}
