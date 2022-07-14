provider "pagerduty" {
  token = "your_token_here"
}


terraform {
  required_providers {
    pagerduty = {
        source = "pagerduty/pagerduty"
    }
  }
}


data "pagerduty_priority" "p1" {
    name = "P1"
}

resource "pagerduty_team" "eo" {
    name = "Event Orchestration Team"
}

# /* escalation policy */
resource "pagerduty_escalation_policy" "eo" {
  name      = "Event Orchestration Escalation Policy"
  num_loops = 3
  rule {
    escalation_delay_in_minutes = 30
    target {
      type = "schedule_reference"
      id   = pagerduty_schedule.foo.id
    }
  }
}

/* USERS */
resource "pagerduty_user" "bart" {
  email       = "bart@foo.test"
  name        = "Bart Simpson"
  role        = "limited_user"
  description = "Spikey-haired boy"
  job_title   = "Rascal"
}

resource "pagerduty_user" "lisa" {
  email       = "lisa@foo.test"
  name        = "Lisa Simpson"
  role        = "admin"
  description = "The brains"
  job_title   = "Supreme Thinker"
}

# /* SCHEDULE */
resource "pagerduty_schedule" "foo" {
  name      = "Event Orchestration Schedule"
  time_zone = "America/Los_Angeles"
  
  layer {
    name                         = "Night Shift"
    start                        = "2020-12-07T20:00:00-08:00"
    rotation_virtual_start       = "2020-12-07T17:00:00-08:00"
    rotation_turn_length_seconds = 86400
    users                        = [pagerduty_user.lisa.id, pagerduty_user.bart.id]

    restriction {
      type              = "daily_restriction"
      start_time_of_day = "17:00:00"
      duration_seconds  = 54000
    }
  }
}

resource "pagerduty_service" "eo" {
    name = "Event Orchestration"
    escalation_policy = pagerduty_escalation_policy.eo.id
    alert_creation = "create_alerts_and_incidents"
}

resource "pagerduty_event_orchestration" "twitchie" {
    name = "Terraforming EO Sample"
    team = pagerduty_team.eo.id
}

resource "pagerduty_event_orchestration_router" "rowdy" {
    event_orchestration = pagerduty_event_orchestration.twitchie.id
    set {
        id = "start"
        rule {
            label = "Events relating to Twitch"
            condition {
              expression = "event.summary matches part 'Jose is awesome'"
            }
            actions {
              route_to = pagerduty_service.eo.id
            }
        }
    }
    catch_all {
      actions {
        route_to = "unrouted"
      }
    }
}

resource "pagerduty_event_orchestration_unrouted" "unrouted" {
 event_orchestration = pagerduty_event_orchestration.twitchie.id
  set {
    id = "start"
    rule {
      label = "Update the summary of un-matched Critical alerts so they're easier to spot"
      condition {
        expression = "event.severity matches 'critical'"
      }
      actions {
        severity = "critical"
        extraction {
          target = "event.summary"
          template = "[P1] {{event.summary}}"
        }
      }
    }
  }
  catch_all {
    actions {
      severity = "info"
    }
  }
}
resource "pagerduty_event_orchestration_service" "www" {
  service = pagerduty_service.eo.id
  set {
    id = "start"
    rule {
      label = "Always apply some consistent event transformations to all events"
      actions {
        variable {
          name = "hostname"
          path = "event.component"
          value = "hostname: (.*)"
          type = "regex"
        }
        extraction {
          # Demonstrating a template-style extraction
          template = "{{variables.hostname}}"
          target = "event.custom_details.hostname"
        }
        extraction {
          # Demonstrating a regex-style extraction
          source = "event.source"
          regex = "www (.*) service"
          target = "event.source"
        }
        # Id of the next set
        route_to = "step-two"
      }
    }
  }
  set {
    id = "step-two"
    rule {
      label = "All critical alerts should be treated as P1 incident"
      condition {
        expression = "event.severity matches 'critical'"
      }
      actions {
        annotate = "Please use our P1 runbook: https://docs.test/p1-runbook"
        priority = data.pagerduty_priority.p1.id
      }
    }
    rule {
      label = "If there's something wrong on the canary let the team know about it in our deployments Slack channel"
      condition {
        expression = "event.custom_details.hostname matches part 'canary'"
      }
      # create webhook action with parameters and headers
      actions {
        automation_action {
          name = "Canary Slack Notification"
          url = "https://our-slack-listerner.test/canary-notification"
          auto_send = true
          parameter {
            key = "channel"
            value = "#my-team-channel"
          }
          parameter {
            key = "message"
            value = "something is wrong with the canary deployment"
          }
          header {
            key = "X-Notification-Source"
            value = "PagerDuty Incident Webhook"
          }
        }
      }
    }
    rule {
      label = "Never bother the on-call for info-level events outside of work hours"
      condition {
        expression = "event.severity matches 'info' and not (now in Mon,Tue,Wed,Thu,Fri 09:00:00 to 17:00:00 America/Los_Angeles)"
      }
      actions {
        suppress = true
      }
    }
  }
  catch_all {
    actions { }
  }
}