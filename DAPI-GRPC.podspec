Pod::Spec.new do |s|
  s.name     = "DAPI-GRPC"
  s.version  = "0.18.0-alpha.1"
  s.license  = "MIT"
  s.authors  = { 'Dash Core Group, Inc.' => 'contact@dash.org' }
  s.homepage = "https://github.com/dashevo/dapi-grpc"
  s.summary = "Decentralized API GRPC"
  s.source = { :git => 'https://github.com/dashevo/dashsync-iOS.git', :tag => 'dapi-0.18.0-alpha.1' }

  s.ios.deployment_target = "12.0"
  s.osx.deployment_target = "10.9"

  # Base directory where the .proto files are.
  src = "dapi-grpc/protos"

  # Run protoc with the Objective-C and gRPC plugins to generate protocol messages and gRPC clients.
  s.dependency "!ProtoCompiler-gRPCPlugin", "~> 1.0"

  # Pods directory corresponding to this app's Podfile, relative to the location of this podspec.
  pods_root = 'Example/Pods'

  # Path where Cocoapods downloads protoc and the gRPC plugin.
  protoc_dir = "#{pods_root}/!ProtoCompiler"
  protoc = "#{protoc_dir}/protoc"
  plugin = "#{pods_root}/!ProtoCompiler-gRPCPlugin/grpc_objective_c_plugin"

  # Directory where the generated files will be placed.
  dir = "#{pods_root}/#{s.name}"

  s.prepare_command = <<-CMD
    pwd
    git submodule update --init
    mkdir -p #{dir}
    #{protoc} \
        --plugin=protoc-gen-grpc=#{plugin} \
        --objc_out=#{dir} \
        --grpc_out=#{dir} \
        -I #{src}/core/v0 \
        -I #{protoc_dir} \
        #{src}/core/v0/core.proto
        
    #{protoc} \
        --plugin=protoc-gen-grpc=#{plugin} \
        --objc_out=#{dir} \
        --grpc_out=#{dir} \
        -I #{src}/platform/v0 \
        -I #{protoc_dir} \
        #{src}/platform/v0/platform.proto
  CMD

  # Files generated by protoc
  s.subspec "Messages" do |ms|
    ms.source_files = "#{dir}/*.pbobjc.{h,m}", "#{dir}/**/*.pbobjc.{h,m}"
    ms.header_mappings_dir = dir
    ms.requires_arc = false
    # The generated files depend on the protobuf runtime.
    ms.dependency "Protobuf"
  end

  # Files generated by the gRPC plugin
  s.subspec "Services" do |ss|
    ss.source_files = "#{dir}/*.pbrpc.{h,m}", "#{dir}/**/*.pbrpc.{h,m}"
    ss.header_mappings_dir = dir
    ss.requires_arc = true
    # The generated files depend on the gRPC runtime, and on the files generated by protoc.
    ss.dependency "gRPC-ProtoRPC"
    ss.dependency "#{s.name}/Messages"
  end

  s.pod_target_xcconfig = {
    # This is needed by all pods that depend on Protobuf:
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) GPB_USE_PROTOBUF_FRAMEWORK_IMPORTS=1',
    # This is needed by all pods that depend on gRPC-RxLibrary:
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
end
