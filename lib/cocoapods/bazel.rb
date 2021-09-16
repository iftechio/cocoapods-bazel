# frozen_string_literal: true

require 'starlark_compiler/build_file'
require 'cocoapods/bazel/config'
require 'cocoapods/bazel/target'
require 'cocoapods/bazel/xcconfig_resolver'
require 'cocoapods/bazel/util'

module Pod
  module Bazel
    def self.post_install(installer:)
      return unless (config = Config.from_podfile(installer.podfile))

      default_xcconfigs = config.default_xcconfigs.transform_values do |xcconfig|
        _name, xcconfig = XCConfigResolver.resolve_xcconfig(xcconfig)
        xcconfig
      end

      UI.titled_section 'Generating Bazel files' do
        sandbox = installer.sandbox
        workspace = installer.config.installation_root
        cocoapods_bazel_path = File.join(sandbox.root, 'cocoapods-bazel')
        FileUtils.mkdir_p cocoapods_bazel_path

        # Ensure we declare the sandbox (Pods/) as a package so each Pod (as a package) belongs to sandbox root package instead
        FileUtils.touch(File.join(installer.config.sandbox_root, 'BUILD.bazel'))

        build_files = Hash.new { |h, k| h[k] = StarlarkCompiler::BuildFile.new(workspace: workspace, package: k) }
        installer.pod_targets.each do |pod_target|
          # package = sandbox.pod_dir(pod_target.pod_name).relative_path_from(workspace).to_s
          # if package.start_with?('..')
          #   raise Informative, <<~MSG
          #     Bazel does not support Pod located outside of current workspace: \"#{package}\".
          #     To fix this, you can move the Pod into workspace,
          #     or you can symlink the Pod inside the workspace by running `ln -s <path_to_pod> .` at workspace root
          #     Then change path declared in Podfile to `./<pod_name>`
          #     Current workspace: #{workspace}
          #   MSG
          # end
          #
          # build_file = build_files[package]

          bazel_label_infos = [[pod_target, nil]] +
                          pod_target.file_accessors.reject { |fa| fa.spec.library_specification? }.map { |fa| [pod_target, fa.spec] }
          bazel_targets_and_labels = bazel_label_infos.map { |args| [args[0], label(args[0], args[1]), args[1]] }
          bazel_targets_and_labels.each { |args|
            target = args[0]
            label = args[1]
            non_library_spec = args[2]
            package_abs = Pathname.new(cocoapods_bazel_path + "/" + label)
            FileUtils.mkdir_p package_abs.to_s
            build_file = build_files[package_abs.relative_path_from(workspace).to_s]
            file_accessors = non_library_spec ? target.file_accessors.select { |fa| fa.spec == non_library_spec } : target.file_accessors.select { |fa| fa.spec.library_specification? }
            all_files = Pod::Sandbox::FileAccessor.all_files(file_accessors)
            for file in all_files
              relative_path = file.relative_path_from(sandbox.pod_dir(target.pod_name))
              new_path = package_abs + relative_path
              unless File.exist? new_path
                FileUtils.mkdir_p File.dirname(new_path)
                File.symlink(file, new_path)
              end
            end
            t = Target.new(installer, workspace, redirect_file_accessors(file_accessors, package_abs), target, package_abs, cocoapods_bazel_path, non_library_spec, default_xcconfigs)
            load = config.load_for(macro: t.type)
            build_file.add_load(of: load[:rule], from: load[:load])
            build_file.add_target StarlarkCompiler::AST::FunctionCall.new(load[:rule], **t.to_rule_kwargs)
          }

        end

        build_files.each_value(&:save!)
        format_files(build_files: build_files, buildifier: config.buildifier, workspace: workspace)

        write_cocoapods_bazel_build_file(cocoapods_bazel_path, workspace, config)
        write_non_empty_default_xcconfigs(cocoapods_bazel_path, default_xcconfigs)
      end
    end

    def self.label(target, non_library_spec)
      non_library_spec ? target.non_library_spec_label(non_library_spec) : target.label
    end

    def self.redirect_file_accessors(file_accessors, new_package)
      file_accessors.map { |f| Pod::Sandbox::FileAccessor.new(Pod::Sandbox::PathList.new(new_package), f.spec_consumer) }
    end

    def self.write_cocoapods_bazel_build_file(path, workspace, config)
      FileUtils.touch(File.join(path, 'BUILD.bazel'))

      cocoapods_bazel_pkg = Pathname.new(path).relative_path_from Pathname.new(workspace)
      configs_build_file = StarlarkCompiler::BuildFile.new(workspace: workspace, package: cocoapods_bazel_pkg)

      configs_build_file.add_load(of: 'string_flag', from: '@bazel_skylib//rules:common_settings.bzl')
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('string_flag', name: 'config', build_setting_default: 'debug', visibility: ['//visibility:public'])
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('config_setting', name: 'debug', flag_values: { ':config' => 'debug' })
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('config_setting', name: 'release', flag_values: { ':config' => 'release' })

      configs_build_file.save!
      format_files(build_files: { cocoapods_bazel_pkg => configs_build_file }, buildifier: config.buildifier, workspace: workspace)
    end

    def self.write_non_empty_default_xcconfigs(path, default_xcconfigs)
      return if default_xcconfigs.empty?

      hash = StarlarkCompiler::AST.new(toplevel: [StarlarkCompiler::AST::Dictionary.new(default_xcconfigs)])

      File.open(File.join(path, 'default_xcconfigs.bzl'), 'w') do |f|
        f << <<~STARLARK
          """
          Default xcconfigs given as options to cocoapods-bazel.
          """

        STARLARK
        f << 'DEFAULT_XCCONFIGS = '
        StarlarkCompiler::Writer.write(ast: hash, io: f)
      end
    end

    def self.format_files(build_files:, buildifier:, workspace:)
      return if build_files.empty?

      args = []
      case buildifier
      when true
        return unless Pod::Executable.which('buildifier')

        args = ['buildifier']
      when String, Array
        args = Array(buildifier)
      else
        return
      end
      args += %w[-type build]

      executable, *args = args
      Pod::Executable.execute_command executable,
                                      args + build_files.each_key.map { |d| File.join workspace, d, 'BUILD.bazel' },
                                      true
    end
  end
end
