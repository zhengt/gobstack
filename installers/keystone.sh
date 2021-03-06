#!/bin/bash -e
## Install and configure the keystone service

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

source ${BASH_SOURCE%/*}/../defaults.sh

# this to check we are on the controller
if [[ -z `ip addr | grep "${CONTROLLER_PUBLIC_IP}"` ]]; then
  echo "This script expects an interface with ${CONTROLLER_PUBLIC_IP}" 1>&2
  exit 1
fi


apt-get install -y keystone python-keyring

mysql -uroot -p${MYSQL_ROOT_PASS} -e \
  "CREATE DATABASE keystone;"
mysql -uroot -p${MYSQL_ROOT_PASS} -e \
  "GRANT ALL ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${MYSQL_KEYSTONE_PASS}';"

sed -i "s|^connection.*|connection = mysql://keystone:${MYSQL_KEYSTONE_PASS}@${CONTROLLER_PUBLIC_IP}/keystone|" \
  /etc/keystone/keystone.conf
sed -i "s|^#\s*admin_token.*|admin_token = ${OS_SERVICE_TOKEN}|" \
  /etc/keystone/keystone.conf
sed -i "s|^#\s*log_dir.*|log_dir = /var/log/keystone|" \
  /etc/keystone/keystone.conf

service keystone restart

# let it start
count=3
while [ "`curl $OS_SERVICE_ENDPOINT 2>/dev/null | awk '/version/ {print \"started\"}'`" != "started" ] && \
  (( count-- > 0 )); do 
  echo "keystone starting..."
  sleep 3
done

# populate the db
su -s /bin/sh -c "keystone-manage db_sync" keystone

# remove the default SQLite db
rm -f /var/lib/keystone/keystone.db

# cron the clean up of expired tokens
(crontab -l 2>&1 | grep -q token_flush) || \
echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' >> /var/spool/cron/crontabs/root


# TODO Maybe all service databases should be created here, as all endpoints are below
#      They are currently created in service install scripts

## now for some tenants, roles and users
# as assigned in deafults.sh
keystone tenant-create --name admin --description "Admin Tenant" --enabled true
keystone tenant-create --name $DEMO_TENANT_NAME --description "$DEMO_TENANT_DESC" --enabled true

# for /etc/keystone/policy.json
keystone role-create --name admin
# for Horizon
keystone role-create --name Member

ADMIN_TENANT_ID=`keystone tenant-list | awk '/\ admin\ / {print $2}'`
DEMO_TENANT_ID=`keystone tenant-list | awk "/\ ${DEMO_TENANT_NAME}\ / {print \\$2}"`

ADMIN_ROLE_ID=`keystone role-list | awk '/\ admin\ / {print $2}'`
MEMBER_ROLE_ID=`keystone role-list | awk '/\ Member\ / {print $2}'`

# from defaults.sh, the OS_* vars refer to the admin user in this tenant
keystone user-create --name $OS_USERNAME \
  --tenant_id $DEMO_TENANT_ID --pass $OS_PASSWORD \
  --email root@localhost --enabled true
ADMIN_USER_ID=`keystone user-list | awk "/\ ${OS_USERNAME}\ / {print \\$2}"`

keystone user-create --name $DEMO_USERNAME \
  --tenant_id $DEMO_TENANT_ID --pass $DEMO_PASSWORD \
  --email ${DEMO_USERNAME}@localhost --enabled true
DEMO_USER_ID=`keystone user-list| awk "/\ ${DEMO_USERNAME}\ / {print \\$2}"`

# give admin user admin role in admin tenant and our example tenant
keystone user-role-add --user $ADMIN_USER_ID --role $ADMIN_ROLE_ID --tenant_id $ADMIN_TENANT_ID
keystone user-role-add --user $ADMIN_USER_ID --role $ADMIN_ROLE_ID --tenant_id $DEMO_TENANT_ID

# give non-admin user Member role in our example tenant
keystone user-role-add --user $DEMO_USER_ID --role $MEMBER_ROLE_ID --tenant_id $DEMO_TENANT_ID

keystone tenant-list
keystone role-list
keystone user-list


## now the endpoints
keystone service-create --name cinder --type volume --description "OpenStack Block Storage Service"
keystone service-create --name cinderv2 --type volumev2 --description "OpenStack Block Storage Service v2"
keystone service-create --name ec2 --type ec2 --description "OpenStack EC2 Compatibility Layer"
keystone service-create --name glance --type image --description "OpenStack Image Service"
keystone service-create --name keystone --type identity --description "OpenStack Identity Service"
keystone service-create --name neutron --type network --description "OpenStack Network Service"
keystone service-create --name nova --type compute --description "OpenStack Compute Service"
keystone service-create --name swift --type object-store --description "OpenStack Object Storage Service"

CINDER_SERVICE_ID=`keystone service-list | awk '/\ cinder\ / {print $2}'`
CINDER_PUBLIC_URL="http://${STORAGE_PUBLIC_IP}:8776/v1/%(tenant_id)s"
CINDER_ADMIN_URL=$CINDER_PUBLIC_URL
CINDER_INTERNAL_URL=$CINDER_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $CINDER_SERVICE_ID \
  --publicurl $CINDER_PUBLIC_URL \
  --adminurl $CINDER_ADMIN_URL \
  --internalurl $CINDER_INTERNAL_URL

CINDER_V2_SERVICE_ID=`keystone service-list | awk '/\ cinderv2\ / {print $2}'`
CINDER_V2_PUBLIC_URL="http://${STORAGE_PUBLIC_IP}:8776/v2/%(tenant_id)s"
CINDER_V2_ADMIN_URL=$CINDER_V2_PUBLIC_URL
CINDER_V2_INTERNAL_URL=$CINDER_V2_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $CINDER_V2_SERVICE_ID \
  --publicurl $CINDER_V2_PUBLIC_URL \
  --adminurl $CINDER_V2_ADMIN_URL \
  --internalurl $CINDER_V2_INTERNAL_URL

EC2_SERVICE_ID=`keystone service-list | awk '/\ ec2\ / {print $2}'`
EC2_PUBLIC_URL="http://${CONTROLLER_PUBLIC_IP}:8773/services/Cloud"
EC2_ADMIN_URL="http://${CONTROLLER_PUBLIC_IP}:8773/services/Admin"
EC2_INTERNAL_URL=$EC2_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $EC2_SERVICE_ID \
  --publicurl $EC2_PUBLIC_URL \
  --adminurl $EC2_ADMIN_URL \
  --internalurl $EC2_INTERNAL_URL

GLANCE_SERVICE_ID=`keystone service-list | awk '/\ glance\ / {print $2}'`
GLANCE_PUBLIC_URL="http://${CONTROLLER_PUBLIC_IP}:9292"
GLANCE_ADMIN_URL=$GLANCE_PUBLIC_URL
GLANCE_INTERNAL_URL=$GLANCE_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $GLANCE_SERVICE_ID \
  --publicurl $GLANCE_PUBLIC_URL \
  --adminurl $GLANCE_ADMIN_URL \
  --internalurl $GLANCE_INTERNAL_URL

KEYSTONE_SERVICE_ID=`keystone service-list | awk '/\ keystone\ / {print $2}'`
KEYSTONE_PUBLIC_URL="http://${CONTROLLER_PUBLIC_IP}:5000/v2"
KEYSTONE_ADMIN_URL=$OS_SERVICE_ENDPOINT
KEYSTONE_INTERNAL_URL=$KEYSTONE_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $KEYSTONE_SERVICE_ID \
  --publicurl $KEYSTONE_PUBLIC_URL \
  --adminurl $KEYSTONE_ADMIN_URL \
  --internalurl $KEYSTONE_INTERNAL_URL

NOVA_SERVICE_ID=`keystone service-list | awk '/\ nova\ / {print $2}'`
NOVA_PUBLIC_URL="http://${CONTROLLER_PUBLIC_IP}:8774/v2/%(tenant_id)s"
NOVA_ADMIN_URL=$NOVA_PUBLIC_URL
NOVA_INTERNAL_URL=$NOVA_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $NOVA_SERVICE_ID \
  --publicurl $NOVA_PUBLIC_URL \
  --adminurl $NOVA_ADMIN_URL \
  --internalurl $NOVA_INTERNAL_URL

NEUTRON_SERVICE_ID=`keystone service-list | awk '/\ neutron\ / {print $2}'`
NEUTRON_PUBLIC_URL="http://${CONTROLLER_PUBLIC_IP}:9696"
NEUTRON_ADMIN_URL=$NEUTRON_PUBLIC_URL
NEUTRON_INTERNAL_URL=$NEUTRON_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $NEUTRON_SERVICE_ID \
  --publicurl $NEUTRON_PUBLIC_URL \
  --adminurl $NEUTRON_ADMIN_URL \
  --internalurl $NEUTRON_INTERNAL_URL

SWIFT_SERVICE_ID=`keystone service-list | awk '/\ swift\ / {print $2}'`
SWIFT_PUBLIC_URL="http://${STORAGE_PUBLIC_IP}:8080/v1/AUTH_%(tenant_id)s"
SWIFT_ADMIN_URL="http://${STORAGE_PUBLIC_IP}:8080/v1"
SWIFT_INTERNAL_URL=$SWIFT_PUBLIC_URL
keystone endpoint-create --region RegionOne \
  --service_id $SWIFT_SERVICE_ID \
  --publicurl $SWIFT_PUBLIC_URL \
  --adminurl $SWIFT_ADMIN_URL \
  --internalurl $SWIFT_INTERNAL_URL

keystone service-list


## and finally, the service tenant and users per service
keystone tenant-create --name service --description "Service Tenant" --enabled true
SERVICE_TENANT_ID=`keystone tenant-list | awk '/\ service\ / {print $2}'`

keystone user-create --name cinder --pass cinder --tenant_id $SERVICE_TENANT_ID --email cinder@localhost --enabled true
keystone user-create --name ec2 --pass ec2 --tenant_id $SERVICE_TENANT_ID --email ec2@localhost --enabled true
keystone user-create --name glance --pass glance --tenant_id $SERVICE_TENANT_ID --email glance@localhost --enabled true
keystone user-create --name keystone --pass keystone --tenant_id $SERVICE_TENANT_ID --email keystone@localhost --enabled true
keystone user-create --name neutron --pass neutron --tenant_id $SERVICE_TENANT_ID --email neutron@localhost --enabled true
keystone user-create --name nova --pass nova --tenant_id $SERVICE_TENANT_ID --email nova@localhost --enabled true
keystone user-create --name swift --pass swift --tenant_id $SERVICE_TENANT_ID --email swift@localhost --enabled true

CINDER_USER_ID=`keystone user-list | awk '/\ cinder\ / {print $2}'`
keystone user-role-add --user $CINDER_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID
EC2_USER_ID=`keystone user-list | awk '/\ ec2\ / {print $2}'`
keystone user-role-add --user $EC2_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID
GLANCE_USER_ID=`keystone user-list | awk '/\ glance\ / {print $2}'`
keystone user-role-add --user $GLANCE_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID
KEYSTONE_USER_ID=`keystone user-list | awk '/\ keystone\ / {print $2}'`
keystone user-role-add --user $KEYSTONE_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID
NEUTRON_USER_ID=`keystone user-list | awk '/\ neutron\ / {print $2}'`
keystone user-role-add --user $NEUTRON_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID
NOVA_USER_ID=`keystone user-list | awk '/\ nova\ / {print $2}'`
keystone user-role-add --user $NOVA_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID
SWIFT_USER_ID=`keystone user-list | awk '/\ swift\ / {print $2}'`
keystone user-role-add --user $SWIFT_USER_ID --role $ADMIN_ROLE_ID --tenant_id $SERVICE_TENANT_ID

keystone user-list

