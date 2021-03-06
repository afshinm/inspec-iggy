#
# Author:: Matt Ray (<matt@chef.io>)
#
# Copyright:: 2018, Chef Software, Inc <legal@chef.io>
#

require 'json'

require 'inspec/objects/control'
require 'inspec/objects/ruby_helper'
require 'inspec/objects/describe'

require 'inspec-iggy/inspec_helper'

module InspecPlugins::Iggy::Terraform
  class Parser
    # makes it easier to change out later
    TAG_NAME = 'iggy_name_'.freeze
    TAG_URL = 'iggy_url_'.freeze

    # boilerplate tfstate parsing
    def self.parse_tfstate(file)
      Inspec::Log.debug "Iggy::Terraform.parse_tfstate file = #{file}"
      begin
        unless File.file?(file)
          STDERR.puts "ERROR: #{file} is an invalid file, please check your path."
          exit(-1)
        end
        JSON.parse(File.read(file))
      rescue JSON::ParserError => e
        STDERR.puts e.message
        STDERR.puts "ERROR: Parsing error in #{file}."
        exit(-1)
      end
    end

    # parse through the JSON for the tagged Resources
    def self.parse_extract(file) # rubocop:disable Metrics/AbcSize
      tfstate = parse_tfstate(file)
      # InSpec profiles extracted
      extracted_profiles = {}

      # iterate over the resources
      tf_resources = tfstate['modules'][0]['resources']
      tf_resources.keys.each do |tf_res|
        tf_res_id = tf_resources[tf_res]['primary']['id']

        # get the attributes, see if any of them have a tagged profile attached
        tf_resources[tf_res]['primary']['attributes'].keys.each do |attr|
          next unless attr.start_with?('tags.' + TAG_NAME)
          Inspec::Log.debug "Iggy::Terraform.parse_extract tf_res = #{tf_res} attr = #{attr} MATCHED TAG"
          # get the URL and the name of the profiles
          name = attr.split(TAG_NAME)[1]
          url = tf_resources[tf_res]['primary']['attributes']["tags.#{TAG_URL}#{name}"]
          if tf_res.start_with?('aws_vpc') # should this be VPC or subnet?
            # if it's a VPC, store it as the VPC id + name
            key = tf_res_id + ':' + name
            Inspec::Log.debug "Iggy::Terraform.parse_extract aws_vpc tagged with InSpec #{key}"
            extracted_profiles[key] = {
              'type' => 'aws_vpc',
              'az' => 'us-west-2',
              'url' => url,
            }
          elsif tf_res.start_with?('aws_instance')
            # if it's a node, get information about the IP and SSH/WinRM
            key = tf_res_id + ':' + name
            Inspec::Log.debug "Iggy::Terraform.parse_extract aws_instance tagged with InSpec #{key}"
            extracted_profiles[key] = {
              'type' => 'aws_instance',
              'public_ip' => tf_resources[tf_res]['primary']['attributes']['public_ip'],
              'key_name' => tf_resources[tf_res]['primary']['attributes']['key_name'],
              'url' => url,
            }
          else
            # should generic AWS just be the default except for instances?
            STDERR.puts "ERROR: #{file} #{tf_res_id} has an InSpec-tagged resource but #{tf_res} is currently unsupported."
            exit(-1)
          end
        end
      end
      Inspec::Log.debug "Iggy::Terraform.parse_extract extracted_profiles = #{extracted_profiles}"
      extracted_profiles
    end

    # parse through the JSON and generate InSpec controls
    def self.parse_generate(file) # rubocop:disable all
      tfstate = parse_tfstate(file)
      absolutename = File.absolute_path(file)

      # InSpec controls generated
      generated_controls = []

      # iterate over the resources
      tfstate['modules'].each do |m|
        tf_resources = m['resources']
        tf_resources.keys.each do |tf_res|
          tf_res_type = tf_resources[tf_res]['type']

          # add translation layer
          if InspecPlugins::Iggy::InspecHelper::TRANSLATED_RESOURCES.key?(tf_res_type)
            Inspec::Log.debug "Iggy::Terraform.parse_generate tf_res_type = #{tf_res_type} #{InspecPlugins::Iggy::InspecHelper::TRANSLATED_RESOURCES[tf_res_type]} TRANSLATED"
            tf_res_type = InspecPlugins::Iggy::InspecHelper::TRANSLATED_RESOURCES[tf_res_type]
          end

          # does this match an InSpec resource?
          if InspecPlugins::Iggy::InspecHelper::RESOURCES.include?(tf_res_type)
            Inspec::Log.debug "Iggy::Terraform.parse_generate tf_res_type = #{tf_res_type} MATCH"
            tf_res_id = tf_resources[tf_res]['primary']['id']

            # insert new control based off the resource's ID
            ctrl = Inspec::Control.new
            ctrl.id = "#{tf_res_type}::#{tf_res_id}"
            ctrl.title = "InSpec-Iggy #{tf_res_type}::#{tf_res_id}"
            ctrl.descriptions[:default] = "#{tf_res_type}::#{tf_res_id} from the source file #{absolutename}\nGenerated by InSpec-Iggy v#{InspecPlugins::Iggy::VERSION}"
            ctrl.impact = '1.0'

            describe = Inspec::Describe.new
            # describes the resourde with the id as argument
            describe.qualifier.push([tf_res_type, tf_res_id])

            # ensure the resource exists
            describe.add_test(nil, 'exist', nil)

            # if there's a match, see if there are matching InSpec properties
            inspec_properties = InspecPlugins::Iggy::InspecHelper.resource_properties(tf_res_type)
            tf_resources[tf_res]['primary']['attributes'].keys.each do |attr|
              if inspec_properties.member?(attr)
                Inspec::Log.debug "Iggy::Terraform.parse_generate #{tf_res_type} inspec_property = #{attr} MATCH"
                value = tf_resources[tf_res]['primary']['attributes'][attr]
                describe.add_test(attr, 'eq', value)
              else
                Inspec::Log.debug "Iggy::Terraform.parse_generate #{tf_res_type} inspec_property = #{attr} SKIP"
              end
            end

            ctrl.add_test(describe)
            generated_controls.push(ctrl)
          else
            Inspec::Log.debug "Iggy::Terraform.parse_generate tf_res_type = #{tf_res_type} SKIP"
          end
        end
      end
      Inspec::Log.debug "Iggy::Terraform.parse_generate generated_controls = #{generated_controls}"
      generated_controls
    end
  end
end
