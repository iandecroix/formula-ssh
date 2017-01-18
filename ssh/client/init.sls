{% set ssh = salt['pillar.get']('ssh') %}


# Install ssh client package
ssh_client_package:
  pkg.installed:
    - name: openssh-client


# Manage the /etc/ssh/ssh_config global ssh user config
ssh_client_/etc/ssh/ssh_config:
  file.managed:
    - name: /etc/ssh/ssh_config
    - source: salt://ssh/client/files/ssh_config.jinja2
    - template: jinja
    - context:
        config: {{ ssh['client']['config'] }}


# Manage the client config files per user
{% for user in ssh['client'].get('users', {}) %}

    {% set user_home = salt['user.info'](user).get('home', '/home/' + user) %}
    {% set user_primary_group = salt['cmd.run']('/usr/bin/id -g -n ' + user) %}

# Manage the presence of the ~/.ssh directory
ssh_client_directory_{{ user }}:
  file.directory:
    - name: {{ user_home }}/.ssh
    - user: {{ user }}
    - group: {{ user_primary_group }}
    - mode: 700


# Manage $HOME/.ssh/environment
ssh_client_{{ user }}_environment:
  file.managed:
    - name: {{ user_home }}/.ssh/environment
    - source: salt://ssh/client/files/environment.jinja2
    - template: jinja
    - user: {{ user }}
    - group: {{ user_primary_group }}
    - mode: 600
    - context:
        config: {{ ssh['client']['users'][user].get('environment', {}) }}

# Manage $HOME/.ssh/config
ssh_client_{{ user }}_config:
  file.managed:
    - name: {{ user_home }}/.ssh/config
    - source: salt://ssh/client/files/ssh_config.jinja2
    - template: jinja
    - user: {{ user }}
    - group: {{ user_primary_group }}
    - mode: 600
    - context:
        config: {{ ssh['client']['users'][user].get('config', {}) }}


# Manage $HOME/.ssh/id_rsa and id_rsa.pub

    {% if ssh['client']['users'][user].get('keypair', 'generate') == 'generate' %}

# Generate the ssh keypair
ssh_client_keypair_{{ user }}_generate:
  cmd.run:
    - name: ssh-keygen -q -N '' -f {{ user_home}}/.ssh/id_rsa
    - runas: {{ user }}
    - unless: test -f {{ user_home}}/.ssh/id_rsa

    {% else %}
        {% for key_file_type in ssh['client']['users'][user]['keypair'] %}

# Set up the keypair from pillar data
ssh_client_keypair_{{ user }}_pillar_{{ key_file_type }}:
  file.managed:
    - name: {{ user_home }}/.ssh/{{ key_file_type }}
    - contents_pillar: ssh:client:users:{{ user }}:keypair:{{ key_file_type }}
    - user: {{ user }}
    - group: {{ user_primary_group }}
    - mode: 600

        {% endfor %}
    {% endif %}

    {% set mine_pub_key_default = ssh['client'].get('mine_pub_key_default', True) %}
    {% if ssh['client']['users'][user].get('mine_keypair', mine_pub_key_default) %}

# Push the users public key to the mine
ssh_client_keypair_{{ user }}_mine_pubkey:
 module.run:
    - name: mine.send
    - alias: ssh_pub_{{ user }}@{{ grains['id'] }}
    - func: cmd.run
    - kwargs:
        cmd: cat {{ user_home }}/.ssh/id_rsa.pub

    {% else %}

# Remove the users public key from the mine
ssh_client_keypair_{{ user }}_mine_pubkey_delete:
 module.run:
    - name: mine.delete
    - alias: ssh_pub_{{ user }}@{{ grains['id'] }}
    - m_fun: ssh_pub_{{ user }}@{{ grains['id'] }}
    - func: cmd.run

    {% endif %}


# Manage $HOME/.ssh/known_hosts

    {% if ssh['client']['users'][user].get('known_hosts', False) %}
        {% if ssh['client']['users'][user]['known_hosts'].get('pillar', False) %}
            {% for pillar_known_host in ssh['client']['users'][user]['known_hosts']['pillar'] %}
                {% set pillar_known_host_state = ssh['client']['users'][user]['known_hosts']['pillar'][pillar_known_host] %}

# Uses the following ssh command to automatically accept the host key:
# ssh -oStrictHostKeyChecking=no root@host.example.com /bin/true
ssh_client_known_hosts_{{ user }}_{{ pillar_known_host }}:
  ssh_known_hosts.{{ pillar_known_host_state }}:
    - name: {{ pillar_known_host }}
    - user: {{ user }}

            {% endfor %}
        {% endif %}
    {% endif %}


    # Iterate over the authorized users to set up for this user
    {% if ssh['client']['users'][user].get('authorized_keys', False) %}
        {% for authorized_user in ssh['client']['users'][user]['authorized_keys'].get('pillar', {}) %}

            {% set public_key = ssh['client']['users'][user]['authorized_keys']['pillar'][authorized_user]['key'] %}
            {% set public_key_state = ssh['client']['users'][user]['authorized_keys']['pillar'][authorized_user].get('state', 'present') %}

# Manage $HOME/.ssh/authorized_keys from pillar data
ssh_client_authorized_keys_pillar_{{ user }}_authorize_{{ authorized_user }}:
  ssh_auth.{{ public_key_state }}:
    - name: {{ public_key }}
    - user: {{ user }}
    - config: {{ user_home }}/.ssh/authorized_keys

        {% endfor %} 
    {% endif %}


    # Iterate over the public keys defined in the pillars that should show up in the mine for this minion
    {% if ssh['client']['users'][user].get('authorized_keys', False) %}
        {% for mined_authorized_user in ssh['client']['users'][user]['authorized_keys'].get('mined', {}) %}

            {% set mined_public_key_match = ssh['client']['users'][user]['authorized_keys']['mined'][mined_authorized_user]['match'] %}
            {% set mined_public_key_state = ssh['client']['users'][user]['authorized_keys']['mined'][mined_authorized_user].get('state', 'present') %}

            # Not very intuitive way of getting the public key
            # So the mine is a dict in first instance - the keys are all grains['id'] of all minions
            # We have the information "user@host" which we can match against. This will hence match on only one specific minion.
            # As public keys are public ;) its ok to have all minions have access to ssh_pub_* in /etc/salt/master.
            # The pillar data then decieds which keys are actually set up.
            {% set matched_public_key = None %}
            {% for mined_member_host, mined_member_pub_key in salt['mine.get']('*', 'ssh_pub_' + mined_public_key_match).items() %}
                {% set matched_public_key = mined_member_pub_key %}
            {% endfor %}

            {% if matched_public_key != None %}

# Manage $HOME/.ssh/authorized_keys from mine data
ssh_client_authorized_keys_mined_{{ user }}_authorize_{{ mined_authorized_user }}:
  ssh_auth.{{ mined_public_key_state }}:
    - name: {{ matched_public_key }}
    - user: {{ user }}
    - config: {{ user_home }}/.ssh/authorized_keys

            {% else %}

ssh_client_authorized_keys_mined_{{ user }}_authorize_{{ mined_authorized_user }}_NOT_FOUND_IN_MINE_FOR_{{ grains['id'] }}:
  cmd.run:
    - name: salt '{{ grains['id'] }}' mine.get '{{ grains['id'] }}' 'ssh_pub_{{ mined_public_key_match }}'; /bin/false
# TODO make this module.run mine.get

            {% endif %}

        {% endfor %}
    {% endif %}


{% endfor %}