# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "cask/config"
require "cask/installer"
require "cask_dependent"
require "missing_formula"
require "formula_installer"
require "development_tools"
require "install"
require "cleanup"
require "upgrade"

module Homebrew
  module Cmd
    class InstallCmd < AbstractCommand
      cmd_args do
        description <<~EOS
          Install a <formula> or <cask>. Additional options specific to a <formula> may be
          appended to the command.

          Unless `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set, `brew upgrade` or `brew reinstall` will be run for
          outdated dependents and dependents with broken linkage, respectively.

          Unless `$HOMEBREW_NO_INSTALL_CLEANUP` is set, `brew cleanup` will then be run for
          the installed formulae or, every 30 days, for all formulae.

          Unless `$HOMEBREW_NO_INSTALL_UPGRADE` is set, `brew install` <formula> will upgrade <formula> if it
          is already installed but outdated.
        EOS
        switch "-d", "--debug",
               description: "If brewing fails, open an interactive debugging session with access to IRB " \
                            "or a shell inside the temporary build directory."
        switch "--display-times",
               env:         :display_install_times,
               description: "Print install times for each package at the end of the run."
        switch "-f", "--force",
               description: "Install formulae without checking for previously installed keg-only or " \
                            "non-migrated versions. When installing casks, overwrite existing files " \
                            "(binaries and symlinks are excluded, unless originally from the same cask)."
        switch "-v", "--verbose",
               description: "Print the verification and post-install steps."
        switch "-n", "--dry-run",
               description: "Show what would be installed, but do not actually install anything."
        [
          [:switch, "--formula", "--formulae", {
            description: "Treat all named arguments as formulae.",
          }],
          [:flag, "--env=", {
            description: "Disabled other than for internal Homebrew use.",
            hidden:      true,
          }],
          [:switch, "--ignore-dependencies", {
            description: "An unsupported Homebrew development option to skip installing any dependencies of any " \
                         "kind. If the dependencies are not already present, the formula will have issues. If " \
                         "you're not developing Homebrew, consider adjusting your PATH rather than using this " \
                         "option.",
          }],
          [:switch, "--only-dependencies", {
            description: "Install the dependencies with specified options but do not install the " \
                         "formula itself.",
          }],
          [:flag, "--cc=", {
            description: "Attempt to compile using the specified <compiler>, which should be the name of the " \
                         "compiler's executable, e.g. `gcc-9` for GCC 9. In order to use LLVM's clang, specify " \
                         "`llvm_clang`. To use the Apple-provided clang, specify `clang`. This option will only " \
                         "accept compilers that are provided by Homebrew or bundled with macOS. Please do not " \
                         "file issues if you encounter errors while using this option.",
          }],
          [:switch, "-s", "--build-from-source", {
            description: "Compile <formula> from source even if a bottle is provided. " \
                         "Dependencies will still be installed from bottles if they are available.",
          }],
          [:switch, "--force-bottle", {
            description: "Install from a bottle if it exists for the current or newest version of " \
                         "macOS, even if it would not normally be used for installation.",
          }],
          [:switch, "--include-test", {
            description: "Install testing dependencies required to run `brew test` <formula>.",
          }],
          [:switch, "--HEAD", {
            description: "If <formula> defines it, install the HEAD version, aka. main, trunk, unstable, master.",
          }],
          [:switch, "--fetch-HEAD", {
            description: "Fetch the upstream repository to detect if the HEAD installation of the " \
                         "formula is outdated. Otherwise, the repository's HEAD will only be checked for " \
                         "updates when a new stable or development version has been released.",
          }],
          [:switch, "--keep-tmp", {
            description: "Retain the temporary files created during installation.",
          }],
          [:switch, "--debug-symbols", {
            depends_on:  "--build-from-source",
            description: "Generate debug symbols on build. Source will be retained in a cache directory.",
          }],
          [:switch, "--build-bottle", {
            description: "Prepare the formula for eventual bottling during installation, skipping any " \
                         "post-install steps.",
          }],
          [:switch, "--skip-post-install", {
            description: "Install but skip any post-install steps.",
          }],
          [:switch, "--skip-link", {
            description: "Install but skip linking the keg into the prefix.",
          }],
          [:flag, "--bottle-arch=", {
            depends_on:  "--build-bottle",
            description: "Optimise bottles for the specified architecture rather than the oldest " \
                         "architecture supported by the version of macOS the bottles are built on.",
          }],
          [:switch, "-i", "--interactive", {
            description: "Download and patch <formula>, then open a shell. This allows the user to " \
                         "run `./configure --help` and otherwise determine how to turn the software " \
                         "package into a Homebrew package.",
          }],
          [:switch, "-g", "--git", {
            description: "Create a Git repository, useful for creating patches to the software.",
          }],
          [:switch, "--overwrite", {
            description: "Delete files that already exist in the prefix while linking.",
          }],
          [:switch, "--ask", {
            description: "Ask for confirmation before downloading and installing formulae. " \
                         "Print bottles and dependencies download size and install size.",
            env:         :ask,
          }],
        ].each do |args|
          options = args.pop
          send(*args, **options)
          conflicts "--cask", args.last
        end
        formula_options
        [
          [:switch, "--cask", "--casks", { description: "Treat all named arguments as casks." }],
          [:switch, "--[no-]binaries", {
            description: "Disable/enable linking of helper executables (default: enabled).",
            env:         :cask_opts_binaries,
          }],
          [:switch, "--require-sha",  {
            description: "Require all casks to have a checksum.",
            env:         :cask_opts_require_sha,
          }],
          [:switch, "--[no-]quarantine", {
            description: "Disable/enable quarantining of downloads (default: enabled).",
            env:         :cask_opts_quarantine,
          }],
          [:switch, "--adopt", {
            description: "Adopt existing artifacts in the destination that are identical to those being installed. " \
                         "Cannot be combined with `--force`.",
          }],
          [:switch, "--skip-cask-deps", {
            description: "Skip installing cask dependencies.",
          }],
          [:switch, "--zap", {
            description: "For use with `brew reinstall --cask`. Remove all files associated with a cask. " \
                         "*May remove files which are shared between applications.*",
          }],
        ].each do |args|
          options = args.pop
          send(*args, **options)
          conflicts "--formula", args.last
        end
        cask_options

        conflicts "--ignore-dependencies", "--only-dependencies"
        conflicts "--build-from-source", "--build-bottle", "--force-bottle"
        conflicts "--adopt", "--force"

        named_args [:formula, :cask], min: 1
      end

      sig { override.void }
      def run
        if args.env.present?
          # Can't use `replacement: false` because `install_args` are used by
          # `build.rb`. Instead, `hide_from_man_page` and don't do anything with
          # this argument here.
          # This odisabled should stick around indefinitely.
          odisabled "brew install --env", "`env :std` in specific formula files"
        end

        args.named.each do |name|
          if (tap_with_name = Tap.with_formula_name(name))
            tap, = tap_with_name
          elsif (tap_with_token = Tap.with_cask_token(name))
            tap, = tap_with_token
          end

          tap&.ensure_installed!
        end

        if args.ignore_dependencies?
          opoo <<~EOS
            #{Tty.bold}`--ignore-dependencies` is an unsupported Homebrew developer option!#{Tty.reset}
            Adjust your PATH to put any preferred versions of applications earlier in the
            PATH rather than using this unsupported option!

          EOS
        end

        begin
          formulae, casks = T.cast(
            args.named.to_formulae_and_casks(warn: false).partition { _1.is_a?(Formula) },
            [T::Array[Formula], T::Array[Cask::Cask]],
          )
        rescue FormulaOrCaskUnavailableError, Cask::CaskUnavailableError
          cask_tap = CoreCaskTap.instance
          if !cask_tap.installed? && (args.cask? || Tap.untapped_official_taps.exclude?(cask_tap.name))
            cask_tap.ensure_installed!
            retry if cask_tap.installed?
          end

          raise
        end

        if casks.any?
          if args.dry_run?
            if (casks_to_install = casks.reject(&:installed?).presence)
              ohai "Would install #{::Utils.pluralize("cask", casks_to_install.count, include_count: true)}:"
              puts casks_to_install.map(&:full_name).join(" ")
            end
            casks.each do |cask|
              dep_names = CaskDependent.new(cask)
                                       .runtime_dependencies
                                       .reject(&:installed?)
                                       .map(&:to_formula)
                                       .map(&:name)
              next if dep_names.blank?

              ohai "Would install #{::Utils.pluralize("dependenc", dep_names.count, plural: "ies", singular: "y",
                                                  include_count: true)} for #{cask.full_name}:"
              puts dep_names.join(" ")
            end
            return
          end

          require "cask/installer"

          installed_casks, new_casks = casks.partition(&:installed?)

          new_casks.each do |cask|
            Cask::Installer.new(
              cask,
              binaries:       args.binaries?,
              verbose:        args.verbose?,
              force:          args.force?,
              adopt:          args.adopt?,
              require_sha:    args.require_sha?,
              skip_cask_deps: args.skip_cask_deps?,
              quarantine:     args.quarantine?,
              quiet:          args.quiet?,
            ).install
          end

          if !Homebrew::EnvConfig.no_install_upgrade? && installed_casks.any?
            require "cask/upgrade"

            Cask::Upgrade.upgrade_casks(
              *installed_casks,
              force:          args.force?,
              dry_run:        args.dry_run?,
              binaries:       args.binaries?,
              quarantine:     args.quarantine?,
              require_sha:    args.require_sha?,
              skip_cask_deps: args.skip_cask_deps?,
              verbose:        args.verbose?,
              quiet:          args.quiet?,
              args:,
            )
          end
        end

        formulae = Homebrew::Attestation.sort_formulae_for_install(formulae) if Homebrew::Attestation.enabled?

        # if the user's flags will prevent bottle only-installations when no
        # developer tools are available, we need to stop them early on
        build_flags = []
        unless DevelopmentTools.installed?
          build_flags << "--HEAD" if args.HEAD?
          build_flags << "--build-bottle" if args.build_bottle?
          build_flags << "--build-from-source" if args.build_from_source?

          raise BuildFlagsError.new(build_flags, bottled: formulae.all?(&:bottled?)) if build_flags.present?
        end

        if build_flags.present? && !Homebrew::EnvConfig.developer?
          opoo "building from source is not supported!"
          puts "You're on your own. Failures are expected so don't create any issues, please!"
        end

        installed_formulae = formulae.select do |f|
          Install.install_formula?(
            f,
            head:              args.HEAD?,
            fetch_head:        args.fetch_HEAD?,
            only_dependencies: args.only_dependencies?,
            force:             args.force?,
            quiet:             args.quiet?,
            skip_link:         args.skip_link?,
            overwrite:         args.overwrite?,
          )
        end

        return if formulae.any? && installed_formulae.empty?

        Install.perform_preinstall_checks_once
        Install.check_cc_argv(args.cc)

        ask_input = lambda {
          ohai "Do you want to proceed with the installation? [Y/y/yes/N/n]"
          accepted_inputs = %w[y yes]
          declined_inputs = %w[n no]
          loop do
            result = $stdin.gets.chomp.strip.downcase
            if accepted_inputs.include?(result)
              puts "Proceeding with installation..."
              break
            elsif declined_inputs.include?(result)
              return
            else
              puts "Invalid input. Please enter 'Y', 'y', or 'yes' to proceed, or 'N' to abort."
            end
          end
        }

        # Build a unique list of formulae to size by including:
        # 1. The original formulae to install.
        # 2. Their outdated dependents (subject to pruning criteria).
        # 3. Optionally, any installed formula that depends on one of these and is outdated.
        compute_sized_formulae = lambda { |f, check_dep: true, upgrade: true|
          sized_formulae = f.flat_map do |formula|
            # Always include the formula itself.
            formula_list = [formula]

            # If there are dependencies, try to gather outdated, bottled ones.
            if formula.deps.any? && check_dep
              outdated_dependents = formula.recursive_dependencies do |_, dep|
                dep_formula = dep.to_formula
                next :prune if dep_formula.deps.empty?
                next :prune if !upgrade || !dep_formula.outdated?
                next :prune unless dep_formula.bottled?
              end.flatten

              # Convert each dependency to its formula.
              formula_list.concat(outdated_dependents.flat_map { |dep| Array(dep.to_formula) })
            end

            formula_list
          end

          # Add any installed formula that depends on one of the sized formulae and is outdated.
          if !Homebrew::EnvConfig.no_installed_dependents_check? && check_dep
            installed_outdated = Formula.installed.select do |installed_formula|
              installed_formula.outdated? &&
                installed_formula.deps.any? { |dep| sized_formulae.include?(dep.to_formula) }
            end
            sized_formulae.concat(installed_outdated)
          end

          # Uniquify based on a string representation (or any unique identifier)
          sized_formulae.uniq(&:to_s)
        }

        # Compute the total sizes (download, installed, and net) for the given formulae.
        compute_total_sizes = lambda { |sized_formulae, debug: false|
          total_download_size  = 0
          total_installed_size = 0
          total_net_size       = 0

          sized_formulae.each do |formula|
            next unless (bottle = formula.bottle)

            # Fetch additional bottle metadata (if necessary).
            bottle.fetch_tab(quiet: !debug)

            total_download_size  += bottle.bottle_size.to_i if bottle.bottle_size
            total_installed_size += bottle.installed_size.to_i if bottle.installed_size

            # Sum disk usage for all installed kegs of the formula.
            next if formula.installed_kegs.none?

            kegs_dep_size = formula.installed_kegs.sum { |keg| keg.disk_usage.to_i }
            total_net_size += bottle.installed_size.to_i - kegs_dep_size if bottle.installed_size
          end

          { download:  total_download_size,
            installed: total_installed_size,
            net:       total_net_size }
        }

        # Main block: if asking the user is enabled, show dependency and size information.
        # This part should be
        if args.ask?
          ohai "Looking for bottles..."

          sized_formulae = compute_sized_formulae.call(installed_formulae, check_dep: true, upgrade: false)
          sizes = compute_total_sizes.call(sized_formulae, debug: args.debug?)

          puts "Formulae: #{sized_formulae.join(", ")}\n\n"
          puts "Download Size: #{disk_usage_readable(sizes[:download])}"
          puts "Install Size:  #{disk_usage_readable(sizes[:installed])}"
          puts "Net Install Size: #{disk_usage_readable(sizes[:net])}" if sizes[:net] != 0

          ask_input.call
        end

        Install.install_formulae(
          installed_formulae,
          build_bottle:               args.build_bottle?,
          force_bottle:               args.force_bottle?,
          bottle_arch:                args.bottle_arch,
          ignore_deps:                args.ignore_dependencies?,
          only_deps:                  args.only_dependencies?,
          include_test_formulae:      args.include_test_formulae,
          build_from_source_formulae: args.build_from_source_formulae,
          cc:                         args.cc,
          git:                        args.git?,
          interactive:                args.interactive?,
          keep_tmp:                   args.keep_tmp?,
          debug_symbols:              args.debug_symbols?,
          force:                      args.force?,
          overwrite:                  args.overwrite?,
          debug:                      args.debug?,
          quiet:                      args.quiet?,
          verbose:                    args.verbose?,
          dry_run:                    args.dry_run?,
          skip_post_install:          args.skip_post_install?,
          skip_link:                  args.skip_link?,
        )

        Upgrade.check_installed_dependents(
          installed_formulae,
          flags:                      args.flags_only,
          installed_on_request:       args.named.present?,
          force_bottle:               args.force_bottle?,
          build_from_source_formulae: args.build_from_source_formulae,
          interactive:                args.interactive?,
          keep_tmp:                   args.keep_tmp?,
          debug_symbols:              args.debug_symbols?,
          force:                      args.force?,
          debug:                      args.debug?,
          quiet:                      args.quiet?,
          verbose:                    args.verbose?,
          dry_run:                    args.dry_run?,
        )

        Cleanup.periodic_clean!(dry_run: args.dry_run?)

        Homebrew.messages.display_messages(display_times: args.display_times?)
      rescue FormulaUnreadableError, FormulaClassUnavailableError,
             TapFormulaUnreadableError, TapFormulaClassUnavailableError => e
        require "utils/backtrace"

        # Need to rescue before `FormulaUnavailableError` (superclass of this)
        # is handled, as searching for a formula doesn't make sense here (the
        # formula was found, but there's a problem with its implementation).
        $stderr.puts Utils::Backtrace.clean(e) if Homebrew::EnvConfig.developer?
        ofail e.message
      rescue FormulaOrCaskUnavailableError, Cask::CaskUnavailableError => e
        Homebrew.failed = true

        # formula name or cask token
        name = case e
        when FormulaOrCaskUnavailableError then e.name
        when Cask::CaskUnavailableError then e.token
        else T.absurd(e)
        end

        if name == "updog"
          ofail "What's updog?"
          return
        end

        opoo e

        reason = MissingFormula.reason(name, silent: true)
        if !args.cask? && reason
          $stderr.puts reason
          return
        end

        # We don't seem to get good search results when the tap is specified
        # so we might as well return early.
        return if name.include?("/")

        require "search"

        package_types = []
        package_types << "formulae" unless args.cask?
        package_types << "casks" unless args.formula?

        ohai "Searching for similarly named #{package_types.join(" and ")}..."

        # Don't treat formula/cask name as a regex
        string_or_regex = name
        all_formulae, all_casks = Search.search_names(string_or_regex, args)

        if all_formulae.any?
          ohai "Formulae", Formatter.columns(all_formulae)
          first_formula = all_formulae.first.to_s
          puts <<~EOS

            To install #{first_formula}, run:
              brew install #{first_formula}
          EOS
        end
        puts if all_formulae.any? && all_casks.any?
        if all_casks.any?
          ohai "Casks", Formatter.columns(all_casks)
          first_cask = all_casks.first.to_s
          puts <<~EOS

            To install #{first_cask}, run:
              brew install --cask #{first_cask}
          EOS
        end
        return if all_formulae.any? || all_casks.any?

        odie "No #{package_types.join(" or ")} found for #{name}."
      end
    end
  end
end
