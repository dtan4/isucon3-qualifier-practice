package "nginx" do
  action :install
end

package "redis" do
  options "--enablerepo=epel"
  action :install
end
