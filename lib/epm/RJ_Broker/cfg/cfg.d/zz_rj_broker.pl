# Ensure the plugin is enabled
$c->{plugins}->{"Sword::Import::RJ_Broker"}->{params}->{disable} = 0;
$c->{plugins}->{"Sword::Unpack::Sub_Zip"}->{params}->{disable} = 0;

# What program do we run to list the contents of the zip file?
$c->{"executables"}->{"ziplist"} = $c->{"executables"}->{"unzip"};

# What is the invocation for getting the list of files in a zip file?
$c->{"invocation"}->{"ziplist"} = '$(ziplist) -l $(SOURCE)';

# Add in the RJ_Broker acceptance type
$c->{sword}->{supported_packages}->{"http://opendepot.org/broker/1.0"} = 
{
  name => "Repository Junction Broker",
  plugin => "Sword::Import::RJ_Broker",
  qvalue => "0.8"
};
