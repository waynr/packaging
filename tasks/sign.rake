def sign_rpm(rpm, sign_flags = nil)

  # To enable support for wrappers around rpm and thus support for gpg-agent
  # rpm signing, we have to be able to tell the packaging repo what binary to
  # use as the rpm signing tool.
  #
  rpm_cmd = ENV['RPM'] || Pkg::Util::Tool.find_tool('rpm')

  # If we're using the gpg agent for rpm signing, we don't want to specify the
  # input for the passphrase, which is what '--passphrase-fd 3' does. However,
  # if we're not using the gpg agent, this is required, and is part of the
  # defaults on modern rpm. The fun part of gpg-agent signing of rpms is
  # specifying that the gpg check command always return true
  #
  if Pkg::Util.boolean_value(ENV['RPM_GPG_AGENT'])
    gpg_check_cmd = "--define '%__gpg_check_password_cmd /bin/true'"
  else
    input_flag = "--passphrase-fd 3"
  end

  # Try this up to 5 times, to allow for incorrect passwords
  Pkg::Util::Execution.retry_on_fail(:times => 5) do
    # This definition of %__gpg_sign_cmd is the default on modern rpm. We
    # accept extra flags to override certain signing behavior for older
    # versions of rpm, e.g. specifying V3 signatures instead of V4.
    #
    sh "#{rpm_cmd} #{gpg_check_cmd} --define '%_gpg_name #{Pkg::Config.gpg_key}' --define '%__gpg_sign_cmd %{__gpg} gpg #{sign_flags} #{input_flag} --batch --no-verbose --no-armor --no-secmem-warning -u %{_gpg_name} -sbo %{__signature_filename} %{__plaintext_filename}' --addsign #{rpm}"
  end

end

def sign_legacy_rpm(rpm)
  sign_rpm(rpm, "--force-v3-sigs --digest-algo=sha1")
end

def rpm_has_sig(rpm)
  %x(rpm -Kv #{rpm} | grep "#{Pkg::Config.gpg_key.downcase}" &> /dev/null)
  $?.success?
end

def sign_deb_changes(file)
  # Lazy lazy lazy lazy lazy
  sign_program = "-p'gpg --use-agent --no-tty'" if ENV['RPM_GPG_AGENT']
  sh "debsign #{sign_program} --re-sign -k#{Pkg::Config.gpg_key} #{file}"
end

# requires atleast a self signed prvate key and certificate pair
# fmri is the full IPS package name with version, e.g.
# facter@facter@1.6.15,5.11-0:20121112T042120Z
# technically this can be any ips-compliant package identifier, e.g. application/facter
# repo_uri is the path to the repo currently containing the package
def sign_ips(fmri, repo_uri)
  %x(pkgsign -s #{repo_uri}  -k #{Pkg::Config.privatekey_pem} -c #{Pkg::Config.certificate_pem} -i #{Pkg::Config.ips_inter_cert} #{fmri})
end

namespace :pl do
  desc "Sign the tarball, defaults to PL key, pass GPG_KEY to override or edit build_defaults"
  task :sign_tar do
    File.exist?("pkg/#{Pkg::Config.project}-#{Pkg::Config.version}.tar.gz") or fail "No tarball exists. Try rake package:tar?"
    load_keychain if Pkg::Util::Tool.find_tool('keychain', :required => false)
    gpg_sign_file "pkg/#{Pkg::Config.project}-#{Pkg::Config.version}.tar.gz"
  end

  desc "Sign mocked rpms, Defaults to PL Key, pass GPG_KEY to override"
  task :sign_rpms, :root_dir do |t, args|
    rpm_dir = args.root_dir || "pkg"

    # Find x86_64 noarch rpms that have been created as hard links and remove them
    rm_r Dir["#{rpm_dir}/*/*/*/x86_64/*.noarch.rpm"]
    # We'll sign the remaining noarch
    all_rpms = Dir["#{rpm_dir}/**/*.rpm"]
    old_rpms    = Dir["#{rpm_dir}/el/4/**/*.rpm"] + Dir["#{rpm_dir}/el/5/**/*.rpm"]
    modern_rpms = Dir["#{rpm_dir}/el/6/**/*.rpm"] + Dir["#{rpm_dir}/el/7/**/*.rpm"] + Dir["#{rpm_dir}/fedora/**/*.rpm"]

    unsigned_rpms = all_rpms - old_rpms - modern_rpms
    unless unsigned_rpms.empty?
      fail "#{unsigned_rpms} are not signed. Please update the automation in the signing task"
    end

    unless old_rpms.empty?
      puts "Signing old rpms..."
      sign_legacy_rpm(old_rpms.join(' '))
    end

    unless modern_rpms.empty?
      puts "Signing modern rpms..."
      sign_rpm(modern_rpms.join(' '))
    end
    # Now we hardlink them back in
    Dir["#{rpm_dir}/*/*/*/i386/*.noarch.rpm"].each do |rpm|
      cd File.dirname(rpm) do
        FileUtils.ln(File.basename(rpm), File.join("..", "x86_64"), :force => true, :verbose => true)
      end
    end
  end

  desc "Sign ips package, uses PL certificates by default, update privatekey_pem, certificate_pem, and ips_inter_cert in project_data.yaml to override."
  task :sign_ips, :repo_uri, :fmri do |t, args|
    repo_uri  = args.repo_uri
    fmri      = args.fmri
    puts "Signing ips packages..."
    sign_ips(fmri, repo_uri)
  end if Pkg::Config.build_ips

  if Pkg::Config.build_gem
    desc "Sign built gems, defaults to PL key, pass GPG_KEY to override or edit build_defaults"
    task :sign_gem do
      FileList["pkg/#{Pkg::Config.gem_name}-#{Pkg::Config.gemversion}*.gem"].each do |gem|
        puts "signing gem #{gem}"
        gpg_sign_file(gem)
      end
    end
  end

  desc "Check if all rpms are signed"
  task :check_rpm_sigs do
    signed = TRUE
    rpms = Dir["pkg/**/*.rpm"]
    print 'Checking rpm signatures'
    rpms.each do |rpm|
      if rpm_has_sig rpm
        print '.'
      else
        puts "#{rpm} is unsigned."
        signed = FALSE
      end
    end
    fail unless signed
    puts "All rpms signed"
  end

  desc "Sign generated debian changes files. Defaults to PL Key, pass GPG_KEY to override"
  task :sign_deb_changes do
    begin
      load_keychain if Pkg::Util::Tool.find_tool('keychain')
      sign_deb_changes("pkg/deb/*/*.changes") unless Dir["pkg/deb/*/*.changes"].empty?
      sign_deb_changes("pkg/deb/*.changes") unless Dir["pkg/deb/*.changes"].empty?
    ensure
      %x(keychain -k mine)
    end
  end

  ##
  # This crazy piece of work establishes a remote repo on the distribution
  # server, ships our packages out to it, signs them, and brings them back.
  #
  namespace :jenkins do
    desc "Sign all locally staged packages on #{Pkg::Config.distribution_server}"
    task :sign_all => "pl:fetch" do
      Dir["pkg/*"].empty? and fail "There were files found in pkg/. Maybe you wanted to build/retrieve something first?"

      # Because rpms and debs are laid out differently in PE under pkg/ they
      # have a different sign task to address this. Rather than create a whole
      # extra :jenkins task for signing PE, we determine which sign task to use
      # based on if we're building PE.
      # We also listen in on the environment variable SIGNING_BUNDLE. This is
      # _NOT_ intended for public use, but rather with the internal promotion
      # workflow for Puppet Enterprise. SIGNING_BUNDLE is the path to a tarball
      # containing a git bundle to be used as the environment for the packaging
      # repo in a signing operation.
      signing_bundle = ENV['SIGNING_BUNDLE']
      rpm_sign_task = Pkg::Config.build_pe ? "pe:sign_rpms" : "pl:sign_rpms"
      deb_sign_task = Pkg::Config.build_pe ? "pe:sign_deb_changes" : "pl:sign_deb_changes"
      sign_tasks    = ["pl:sign_tar", rpm_sign_task, deb_sign_task]
      sign_tasks    << "pl:sign_gem" if Pkg::Config.build_gem
      remote_repo   = remote_bootstrap(Pkg::Config.distribution_server, 'HEAD', nil, signing_bundle)
      build_params  = remote_buildparams(Pkg::Config.distribution_server, Pkg::Config)
      Pkg::Util::Net.rsync_to('pkg', Pkg::Config.distribution_server, remote_repo)
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "cd #{remote_repo} ; rake #{sign_tasks.join(' ')} PARAMS_FILE=#{build_params}")
      Pkg::Util::Net.rsync_from("#{remote_repo}/pkg/", Pkg::Config.distribution_server, "pkg/")
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "rm -rf #{remote_repo}")
      Pkg::Util::Net.remote_ssh_cmd(Pkg::Config.distribution_server, "rm #{build_params}")
      puts "Signed packages staged in 'pkg/ directory"
    end
  end
end

