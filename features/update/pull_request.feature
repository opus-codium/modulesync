Feature: Create a pull-request/merge-request after update

  Scenario: Creating a GitHub PR with an update
    Given a basic setup with a puppet module "puppet-test" from "fakenamespace"
    And a directory named "moduleroot"
    And I set the environment variables to:
      | variable     | value  |
      | GITHUB_TOKEN | foobar |
    When I run `msync update --noop --branch managed_update --pr`
    Then the output should contain "Would submit PR "
    And the exit status should be 0
    And the puppet module "puppet-test" from "fakenamespace" should have no commits made by "Aruba"

  Scenario: Creating a GitLab MR with an update
    Given a basic setup with a puppet module "puppet-test" from "fakenamespace"
    And a directory named "moduleroot"
    And I set the environment variables to:
      | variable     | value  |
      | GITLAB_TOKEN | foobar |
    When I run `msync update --noop --branch managed_update --pr`
    Then the output should contain "Would submit MR "
    And the exit status should be 0
    And the puppet module "puppet-test" from "fakenamespace" should have no commits made by "Aruba"

  Scenario: Ask for PR without credentials
    Given a basic setup with a puppet module "puppet-test" from "fakenamespace"
    And a file named "managed_modules.yml" with:
      """
      ---
      puppet-test:
        gitlab: {}
      """
    And a directory named "moduleroot"
    When I run `msync update --noop --pr`
    Then the stderr should contain "No GitLab token specified to create a merge request"
    And the exit status should be 1
    And the puppet module "puppet-test" from "fakenamespace" should have no commits made by "Aruba"