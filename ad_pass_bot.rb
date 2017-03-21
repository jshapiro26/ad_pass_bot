require 'rubygems'
require 'net/ldap'
require 'slack-ruby-client'
require 'active_support/core_ext/numeric/time'
require 'dotenv'
require 'pry-nav'
Dotenv.load

# Initialize hashes and arrays for later
users = {}
users_to_notify = {}
accounts_expiring = {}
ous_to_check = [ENV['OU_1'], ENV['OU_2'], ENV['OU_3']]

# How many days from password change does a password expire?
expire_after = ENV['EXPIRE_AFTER'].to_i

## AD
# Initialize connection to AD
ldap = Net::LDAP.new :host => ENV['AD_HOST'],
  :port => 636,
  :base => ENV['AD_BASE'],
  :encryption => :simple_tls,
  :auth => {
    :method => :simple,
    :username => ENV['AD_USERNAME'],
    :password => ENV['AD_PASSWORD']
  }

# Convert Windows NT Time to Unix epoch time
def convert_time(int)
  Time.at(((int)/10000000) - 11644473600)
end

# Find all users and relevant attributes
ous_to_check.each do |ou|
  filter = Net::LDAP::Filter.eq("ObjectClass", "user")
  treebase = "OU=#{ou},#{ENV['TREEBASE']}"

  ldap.search(:base => treebase, :filter => filter) do |entry|
    attributes = {}
    if entry.dn.include?(ENV['ACCT_EXP_GROUP'])
      if entry.respond_to?(:manager)
        attributes[:accountExpiresAt] = convert_time(entry.accountexpires.join.to_i)
        attributes[:manager] = entry.manager.join
      else
        attributes[:accountExpiresAt] = convert_time(entry.accountexpires.join.to_i)
        attributes[:manager] = "No Manager Listed"
      end
    end
    attributes[:mail] = entry.mail.join.downcase
    attributes[:PwdExpireTime] = convert_time(entry.PwdLastSet.join.to_i) + expire_after.days
    users[entry.name.join] = attributes
  end
end

# Output All users for logging
puts "Found users: #{users}"

# Determine users with passwords about to expire
users.each do |user, attr|
  # Only include users with passwords that will expire in 5 days and up to 1 day past expiry
  if (-5..1).include?((Time.now - attr[:PwdExpireTime])/86400)
    users_to_notify[attr[:mail]] = {:PwdExpireTime => attr[:PwdExpireTime].strftime("%A, %d %b %Y %l:%M %p")}
  elsif attr.keys.include?(:accountExpiresAt) && (-5..1).include?((Time.now - attr[:accountExpiresAt])/86400)
    accounts_expiring[attr[:mail]] = {:accountExpiresAt => attr[:accountExpiresAt].strftime("%A, %d %b %Y %l:%M %p"), :manager => attr[:manager]}
  else
    puts "Will not notify #{user}, password expires in greater than 5 days: #{attr[:PwdExpireTime]}"
  end
end

# Map manager email address to expiring contractor
managers = {}
accounts_expiring.each { |m, v| managers[v[:manager].split(",").first.split("=").last] = users[v[:manager].split(",").first.split("=").last][:mail]  }
managers.each do |manager, email|
  accounts_expiring.each do |_ , contractor|
    if contractor[:manager].include?(manager)
      contractor[:manager_email] = email
    end
  end
end

## Slack
#Initialize Slack Connection
Slack.configure do |config|
  config.token = ENV['SLACK_API_TOKEN']
end
client = Slack::Web::Client.new
slack_users = client.users_list.to_hash

# Notify users of expiring passwords
if !users_to_notify.empty?
  # Find Slack usernames and add to hash
  slack_users["members"].each do |user|
    if users_to_notify.include?(user["profile"]["email"])
      users_to_notify[user["profile"]["email"]][:slack_name] = user["name"]
    end
  end
  # Notify users and output user for logging
  users_to_notify.each do |user, attr|
    if !attr[:slack_name].nil?
      client.chat_postMessage(channel: "@#{attr[:slack_name]}", text: "Your Active Directory [e-mail] password will expire in less than 5 days at: #{attr[:PwdExpireTime]}. Reset your password by going to: #{ENV['PW_RESET_URL']}", as_user: true)
      puts "Notified #{user} with slack name: #{attr[:slack_name]} that their password will expire at #{attr[:PwdExpireTime]}"
    else
      client.chat_postMessage(channel: "@#{ENV['BACKUP_SLACK_USER']}", text: "The AD password for #{user} will expire in less than 5 days at: #{attr[:PwdExpireTime]}. They do not have a slack account. Please notify them to reset their password by going to: #{ENV['PW_RESET_URL']}", as_user: true)
      puts "#{user} does not have a slack name, Sent a message to #{ENV['BACKUP_SLACK_USER']}"
    end
  end
end

# Notify managers of expiring contractor accounts
if !accounts_expiring.empty?
  accounts_expiring.each do |email, data|
    slack_manager_data = slack_users["members"].select{ |k, v| k["profile"]["email"] == data[:manager_email]}
    manager_slack_name = slack_manager_data.first["name"]
    client.chat_postMessage(channel: "@#{manager_slack_name}", text: "Contractor's account with email #{email} is expiring in less than 5 days at: #{data[:accountExpiresAt]} ", as_user: true)
  end
end









