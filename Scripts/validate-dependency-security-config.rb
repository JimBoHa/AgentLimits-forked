#!/usr/bin/ruby

require "yaml"

def fail_validation(message)
  warn "Dependency security configuration invalid: #{message}"
  exit 78
end

def load_yaml(path, contents = nil)
  document = YAML.safe_load(
    contents || File.read(path),
    permitted_classes: [],
    aliases: false
  )
  fail_validation("#{path} must contain a mapping") unless document.is_a?(Hash)
  document
rescue Errno::ENOENT, Psych::Exception => error
  fail_validation("#{path}: #{error.message}")
end

def exact_keys(mapping, expected, location)
  fail_validation("#{location} must be a mapping") unless mapping.is_a?(Hash)
  actual = mapping.keys.map(&:to_s).sort
  return if actual == expected.sort

  fail_validation("#{location} keys were #{actual.inspect}, expected #{expected.sort.inspect}")
end

def pinned_action?(value, repository)
  value.is_a?(String) && value.match?(%r{\A#{Regexp.escape(repository)}@[0-9a-f]{40}\z})
end

def validate_workflow(path)
  raw = File.read(path)
  workflow = load_yaml(path, raw)
  exact_keys(workflow, %w[concurrency jobs name on permissions], "workflow")
  fail_validation("workflow name changed") unless workflow["name"] == "Dependency Review"

  triggers = workflow["on"]
  exact_keys(triggers, ["pull_request"], "on")
  pull_request = triggers["pull_request"]
  unless pull_request.nil? || pull_request == {}
    fail_validation("pull_request trigger must not narrow branches or event types")
  end

  permissions = workflow["permissions"]
  exact_keys(permissions, ["contents"], "permissions")
  fail_validation("contents permission must remain read-only") unless permissions["contents"] == "read"

  expected_concurrency = {
    "group" => "${{ github.workflow }}-${{ github.event.pull_request.number }}",
    "cancel-in-progress" => true
  }
  fail_validation("concurrency policy changed") unless workflow["concurrency"] == expected_concurrency

  jobs = workflow["jobs"]
  exact_keys(jobs, ["dependency-review"], "jobs")
  job = jobs["dependency-review"]
  exact_keys(job, %w[name runs-on steps timeout-minutes], "dependency-review job")
  fail_validation("required check name changed") unless job["name"] == "Block vulnerable dependency changes"
  fail_validation("runner changed") unless job["runs-on"] == "ubuntu-latest"
  fail_validation("timeout changed") unless job["timeout-minutes"] == 10

  steps = job["steps"]
  fail_validation("dependency-review job must contain exactly three steps") unless steps.is_a?(Array) && steps.length == 3

  checkout, exceptions, review = steps
  exact_keys(checkout, %w[name uses with], "checkout step")
  fail_validation("checkout action is not commit-pinned") unless pinned_action?(checkout["uses"], "actions/checkout")
  expected_checkout_inputs = {"fetch-depth" => 0, "persist-credentials" => false}
  fail_validation("checkout inputs changed") unless checkout["with"] == expected_checkout_inputs

  exact_keys(exceptions, %w[env id name run], "exception-validation step")
  fail_validation("exception-validation output ID changed") unless exceptions["id"] == "dependency-exceptions"
  expected_environment = {
    "BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
    "HEAD_SHA" => "${{ github.event.pull_request.head.sha }}"
  }
  fail_validation("exception-validation refs changed") unless exceptions["env"] == expected_environment
  expected_run = <<~'SHELL'.strip
    set -euo pipefail

    validator="$RUNNER_TEMP/dependency-exceptions.sh"
    validator_path="Scripts/dependency-exceptions.sh"
    if git cat-file -e "$BASE_SHA:$validator_path" 2>/dev/null; then
      git show "$BASE_SHA:$validator_path" > "$validator"
    else
      cp "$validator_path" "$validator"
    fi
    chmod 500 "$validator"
    "$validator" prepare-pull-request \
      ".github/dependency-review-exceptions.json" \
      "$BASE_SHA" \
      "$HEAD_SHA" \
      "$GITHUB_OUTPUT"
  SHELL
  fail_validation("exception-validation command changed") unless exceptions["run"].strip == expected_run

  exact_keys(review, %w[name uses with], "dependency-review step")
  fail_validation("dependency-review action is not commit-pinned") unless pinned_action?(review["uses"], "actions/dependency-review-action")
  expected_inputs = {
    "allow-ghsas" => "${{ steps.dependency-exceptions.outputs.allow-ghsas }}",
    "comment-summary-in-pr" => "never",
    "fail-on-scopes" => "runtime, development, unknown",
    "fail-on-severity" => "moderate",
    "vulnerability-check" => true,
    "warn-only" => false
  }
  fail_validation("dependency-review inputs changed") unless review["with"] == expected_inputs

  pinned_comments = raw.scan(/^\s*uses:\s+actions\/(?:checkout|dependency-review-action)@[0-9a-f]{40}\s+#\s+v[0-9]+\.[0-9]+\.[0-9]+\s*$/)
  fail_validation("action pins need exact semantic-version comments") unless pinned_comments.length == 2
  fail_validation("workflow references secrets") if raw.match?(/\$\{\{\s*secrets\./)
end

def validate_dependabot(path)
  config = load_yaml(path)
  exact_keys(config, %w[updates version], "dependabot configuration")
  fail_validation("Dependabot schema version changed") unless config["version"] == 2
  updates = config["updates"]
  fail_validation("expected exactly two Dependabot update groups") unless updates.is_a?(Array) && updates.length == 2

  expected = {
    "swift" => {"day" => "monday", "interval" => "weekly", "time" => "09:00", "timezone" => "America/Los_Angeles"},
    "github-actions" => {"day" => "monday", "interval" => "weekly", "time" => "09:30", "timezone" => "America/Los_Angeles"}
  }
  updates.each do |update|
    exact_keys(update, ["directory", "open-pull-requests-limit", "package-ecosystem", "schedule"], "Dependabot update")
    ecosystem = update["package-ecosystem"]
    fail_validation("unexpected Dependabot ecosystem") unless expected.key?(ecosystem)
    fail_validation("Dependabot directory changed") unless update["directory"] == "/"
    fail_validation("Dependabot pull-request limit changed") unless update["open-pull-requests-limit"] == 5
    fail_validation("Dependabot schedule changed for #{ecosystem}") unless update["schedule"] == expected.delete(ecosystem)
  end
  fail_validation("Dependabot ecosystem is missing") unless expected.empty?
end

fail_validation("expected workflow and Dependabot paths") unless ARGV.length == 2
validate_workflow(ARGV[0])
validate_dependabot(ARGV[1])
