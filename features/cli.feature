Feature: CLI
  ModuleSync needs to have a robust command line interface

  Scenario: When passing no arguments to the msync command
    When I run `msync`
    And the output should match /Commands:/

  Scenario: When passing invalid arguments to the msync update command
    When I run `msync update`
    And the output should match /No value provided for required option/

  Scenario: When passing invalid arguments to the msync hook command
    When I run `msync hook`
    And the output should match /Commands:/

  Scenario: When running the help subcommand
    When I run `msync help`
    And the output should match /Commands:/

  Scenario: When overriding a setting from the config file on the command line
    Given a puppet module "puppet-test" from "maestrodev"
    And a file named "managed_modules.yml" with:
      """
      ---
        - puppet-test
      """
    And a file named "modulesync.yml" with:
      """
      ---
      namespace: default
      """
    And a git_base option appended to "modulesync.yml" for local tests
    And a directory named "moduleroot"
    When I run `msync update --noop --namespace maestrodev`
    Then the exit status should be 0
    And the output should match /Syncing maestrodev/
