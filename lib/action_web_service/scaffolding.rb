require 'benchmark'
require 'pathname'

module ActionWebService
  module Scaffolding # :nodoc:
    class ScaffoldingError < ActionWebServiceError # :nodoc:
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    # Web service invocation scaffolding provides a way to quickly invoke web service methods in a controller. The
    # generated scaffold actions have default views to let you enter the method parameters and view the
    # results.
    #
    # Example:
    #
    #   class ApiController < ActionController
    #     web_service_scaffold :invoke
    #   end
    #
    # This example generates an +invoke+ action in the +ApiController+ that you can navigate to from
    # your browser, select the API method, enter its parameters, and perform the invocation.
    #
    # If you want to customize the default views, create the following views in "app/views":
    #
    # * <tt>action_name/methods.html.erb</tt>
    # * <tt>action_name/parameters.html.erb</tt>
    # * <tt>action_name/result.html.erb</tt>
    # * <tt>action_name/layout.html.erb</tt>
    #
    # Where <tt>action_name</tt> is the name of the action you gave to ClassMethods#web_service_scaffold.
    #
    # You can use the default views in <tt>RAILS_DIR/lib/action_web_service/templates/scaffolds</tt> as
    # a guide.
    module ClassMethods
      # Generates web service invocation scaffolding for the current controller. The given action name
      # can then be used as the entry point for invoking API methods from a web browser.
      def web_service_scaffold(action_name)
        #DK NOTE: Here we try to add the scaffold directory to the view_paths....
        #First we just shove it in there... next cut we will match and insert if not found!!!
        
        append_view_path(File.dirname(__FILE__) + "/templates/scaffolds/")
        
        view_paths.each do |a_path|   
          $stderr.puts "path: #{a_path}"           
        end
          
        $stderr.puts "Am in the web_service_scaffold call!!!"
        add_template_helper(Helpers)
        $stderr.puts "Post add_template"
        
        module_eval <<-"end_eval", __FILE__, __LINE__ + 1
          def #{action_name}
            $stderr.puts "in the #{action_name} method"
            if request.get?
              $stderr.puts "in the get...."
              setup_invocation_assigns
              $stderr.puts "post setup_invocation_assigns...."
              render_invocation_scaffold 'methods'
            end
          end

          def #{action_name}_method_params
            if request.get?
              setup_invocation_assigns
              render_invocation_scaffold 'parameters'
            end
          end

          def #{action_name}_submit
            if request.post?
              setup_invocation_assigns
              protocol_name = params['protocol'] ? params['protocol'].to_sym : :soap
              case protocol_name
              when :soap
                @protocol = Protocol::Soap::SoapProtocol.create(self)
                $stderr.puts "protocol is soap"

              when :xmlrpc
                @protocol = Protocol::XmlRpc::XmlRpcProtocol.create(self)
                $stderr.puts "protocol is xml"
                
              end
              bm = Benchmark.measure do
                $stderr.puts "break 0"
                #session[:scaffold_service] =@scaffold_service
                #session[:scaffold_service_api] = @scaffold_service.api
                @protocol.register_api(@scaffold_service.api)
                post_params = params['method_params'] ? params['method_params'].dup : nil
                params = []
                $stderr.puts "break 1"
                @scaffold_method.expects.each_with_index do |spec, i|
                  params << post_params[i.to_s]
                end if @scaffold_method.expects
                $stderr.puts "break 2"
                params = @scaffold_method.cast_expects(params)
                $stderr.puts "break 3"
                method_name = public_method_name(@scaffold_service.name, @scaffold_method.public_name)
                $stderr.puts "break 4"
                @method_request_xml = @protocol.encode_request(method_name, params, @scaffold_method.expects)
                $stderr.puts "break 5"
                new_request = @protocol.encode_action_pack_request(@scaffold_service.name, @scaffold_method.public_name, @method_request_xml)
                $stderr.puts "break 6"
                prepare_request(new_request, @scaffold_service.name, @scaffold_method.public_name)
                $stderr.puts "break 7"
                self.request = new_request
                if @scaffold_container.dispatching_mode != :direct
                  request.parameters['action'] = @scaffold_service.name
                end
                puts "sending the dispatch"
                dispatch_web_service_request
                puts "back from the dispatch"
                @method_response_xml = response.body
                method_name, obj = @protocol.decode_response(@method_response_xml)
                puts "back from decoding the response"
                return if handle_invocation_exception(obj)
                @method_return_value = @scaffold_method.cast_returns(obj)
              end
              @method_elapsed = bm.real
              reset_invocation_response
              render_invocation_scaffold 'result'
            end
          end

          private
            def setup_invocation_assigns
              @scaffold_class = self.class
              @scaffold_action_name = "#{action_name}"
              @scaffold_container = WebServiceModel::Container.new(self)
              if params['service'] && params['method']
                @scaffold_service = @scaffold_container.services.find{ |x| x.name == params['service'] }
                @scaffold_method = @scaffold_service.api_methods[params['method']]
              end
            end

            def render_invocation_scaffold(action)
              customized_template = "\#{self.class.controller_path}/#{action_name}/\#{action}"
              #default_template = scaffold_path(action)
              default_template = action
              begin
                content = view_context.render(:file => customized_template)
              rescue ActionView::MissingTemplate
                logger.debug "caught the MissingTemplate..."
                content = view_context.render(:file => default_template)
              end
              # @template.instance_variable_set("@content_for_layout", content)
              #if self.active_layout.nil?
              #  render :file => scaffold_path("layout")
              #else
              #  render :file => self.active_layout, :use_full_path => true
              #end
              
              @content_for_layout = content
              #DK REVISIT:::::::::
              unless self.action_has_layout?
                render :file => "layout", :layout => false
              else
                render :file => "/layouts/"+self.send(:_default_layout), :use_full_path => true
              end
            end

            def scaffold_path(template_name)
              File.dirname(__FILE__) + "/templates/scaffolds/" + template_name + ".html.erb"
            end

            def reset_invocation_response
              #DK NOTE: the erase_render_results was deprecated. I believe the following will
              #         accomplish what it used to do   
              #  erase_render_results
              self.instance_variable_set(:@_response_body, nil)
              #DK NOTE: it looks like this changed too!
              #response.instance_variable_set :@header, Rack::Utils::HeaderHash.new(::ActionController::Response::DEFAULT_HEADERS.merge("cookie" => []))
              response.instance_variable_set :@header, Rack::Utils::HeaderHash.new("cookie" => [], 'Content-Type' => 'text/html')
            end

            def public_method_name(service_name, method_name)
              if web_service_dispatching_mode == :layered && @protocol.is_a?(ActionWebService::Protocol::XmlRpc::XmlRpcProtocol)
                service_name + '.' + method_name
              else
                method_name
              end
            end

            def prepare_request(new_request, service_name, method_name)
              new_request.parameters.update(request.parameters)
              request.env.each{ |k, v| new_request.env[k] = v unless new_request.env.has_key?(k) }
              if web_service_dispatching_mode == :layered && @protocol.is_a?(ActionWebService::Protocol::Soap::SoapProtocol)
                new_request.env['HTTP_SOAPACTION'] = "/\#{controller_name()}/\#{service_name}/\#{method_name}"
              end
            end

            def handle_invocation_exception(obj)
              exception = nil
              if obj.respond_to?(:detail) && obj.detail.respond_to?(:cause) && obj.detail.cause.is_a?(Exception)
                exception = obj.detail.cause
              elsif obj.is_a?(XMLRPC::FaultException)
                exception = obj
              end
              return unless exception
              reset_invocation_response
              rescue_action(exception)
              true
            end
        end_eval
      end
    end

    module Helpers # :nodoc:
      def method_parameter_input_fields(method, type, field_name_base, idx, was_structured=false)
        if type.array?
          return content_tag('em', "Typed array input fields not supported yet (#{type.name})")
        end
        if type.structured?
          return content_tag('em', "Nested structural types not supported yet (#{type.name})") if was_structured
          parameters = ""
          type.each_member do |member_name, member_type|
            label = method_parameter_label(member_name, member_type)
            nested_content = method_parameter_input_fields(
              method,
              member_type,
              "#{field_name_base}[#{idx}][#{member_name}]",
              idx,
              true)
            if member_type.custom?
              parameters << content_tag('li', label)
              parameters << content_tag('ul', nested_content)
            else
              parameters << content_tag('li', label + ' ' + nested_content)
            end
          end
          content_tag('ul', parameters)
        else
          # If the data source was structured previously we already have the index set          
          field_name_base = "#{field_name_base}[#{idx}]" unless was_structured
          
          case type.type
          when :int
            text_field_tag "#{field_name_base}"
          when :string
            text_field_tag "#{field_name_base}"
          when :base64
            text_area_tag "#{field_name_base}", nil, :size => "40x5"
          when :bool
            radio_button_tag("#{field_name_base}", "true") + " True" +
            radio_button_tag("#{field_name_base}", "false") + "False"
          when :float
            text_field_tag "#{field_name_base}"
          when :time, :datetime
            time = Time.now
            i = 0
            %w|year month day hour minute second|.map do |name|
              i += 1
              send("select_#{name}", time, :prefix => "#{field_name_base}[#{i}]", :discard_type => true)
            end.join
          when :date
            date = Date.today
            i = 0
            %w|year month day|.map do |name|
              i += 1
              send("select_#{name}", date, :prefix => "#{field_name_base}[#{i}]", :discard_type => true)
            end.join
          end
        end
      end

      def method_parameter_label(name, type)
        name.to_s.capitalize + ' (' + type.human_name(false) + ')'
      end

      def service_method_list(service)
        action = @scaffold_action_name + '_method_params'
        methods = service.api_methods_full.sort {|a, b| a[1] <=> b[1]}.map do |desc, name|
          content_tag("li", link_to(desc, :action => action, :service => service.name, :method => name)).html_safe
        end
        content_tag("ul", methods.join("\n").html_safe)
      end
    end

    module WebServiceModel # :nodoc:
      class Container # :nodoc:
        attr :services
        attr :dispatching_mode

        def initialize(real_container)
          @real_container = real_container
          @dispatching_mode = @real_container.class.web_service_dispatching_mode
          @services = []
          if @dispatching_mode == :direct
            @services << Service.new(@real_container.controller_name, @real_container)
          else
            @real_container.class.web_services.each do |name, obj|
              @services << Service.new(name, @real_container.instance_eval{ web_service_object(name) })
            end
          end
        end
      end

      class Service # :nodoc:
        attr :name
        attr :object
        attr :api
        attr :api_methods
        attr :api_methods_full

        def initialize(name, real_service)
          @name = name.to_s
          @object = real_service
          @api = @object.class.web_service_api
          if @api.nil?
            raise ScaffoldingError, "No web service API attached to #{object.class}"
          end
          @api_methods = {}
          @api_methods_full = []
          @api.api_methods.each do |name, method|
            @api_methods[method.public_name.to_s] = method
            @api_methods_full << [method.to_s, method.public_name.to_s]
          end
        end

        def to_s
          self.name.camelize
        end
      end
    end
  end
end