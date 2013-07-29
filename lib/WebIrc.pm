package WebIrc;

=head1 NAME

WebIrc - IRC client on web

=head1 SYNOPSIS

=head2 Production

  hypnotoad script/web_irc

=head2 Development

  morbo script/web_irc

=head1 DESCRIPTION

L<WebIrc> is a web frontend for IRC with additional features such as:

=over 4

=item Avatars

The chat contains profile pictures which can be retrieved from Facebook
or from gravatar.com.

=item Include external resources

Links to images and video will be displayed inline. No need to click on
the link to view the data.

=item Always online

The backend server will keep you logged in and logs all the activity
in your archive.

=item Archive

All chats will be logged and indexed, which allow you to search in
earlier conversations.

=back

=head1 SEE ALSO

=over 4

=item L<WebIrc::Archive>

Mojolicious controller for IRC logs.

=item L<WebIrc::Client>

Mojolicious controller for IRC chat.

=item L<WebIrc::User>

Mojolicious controller for user data.

=item L<WebIrc::Core>

Backend functionality.

=back

=cut

use Mojo::Base 'Mojolicious';
use File::Spec::Functions qw(catfile tmpdir);
use WebIrc::Core;
use Mojo::Redis;

unless($ENV{LESSC_BIN} //= '') {
  for(split /:/, $ENV{PATH} || '') {
    next unless -e "$_/lessc"; # -e because it might be a symlink
    $ENV{LESSC_BIN} = "$_/lessc";
    last;
  }
}

unless($ENV{YUI_COMPRESSOR_BIN} //= '') {
  for(split /:/, $ENV{PATH} || '') {
    next unless -e "$_/yui-compressor"; # -e because it might be a symlink
    $ENV{YUI_COMPRESSOR_BIN} = "$_/yui-compressor";
    last;
  }
}

=head1 ATTRIBUTES

=head2 archive

Holds a L<WebIrc::Core::Archive> object.

=head2 core

Holds a L<WebIrc::Core> object.

=cut

has archive => sub {
  my $self = shift;
  WebIrc::Core::Archive->new($self->config->{archive} || $self->path_to('archive'));
};

has core => sub {
  my $self = shift;
  my $core = WebIrc::Core->new;

  $core->redis->server($self->redis->server);
  $core;
};

=head1 METHODS

=head2 startup

This method will run once at server start

=cut

sub startup {
  my $self   = shift;
  my $config = $self->plugin('Config');

  $config->{name} ||= 'Wirc';
  $config->{backend}{lock_file} ||= catfile(tmpdir, 'wirc-backend.lock');

  $self->plugin('Mojolicious::Plugin::UrlWith');
  $self->plugin('WebIrc::Plugin::Helpers');
  $self->secret($config->{secret} || die '"secret" is required in config file');
  $self->sessions->default_expiration(86400 * 30);
  $self->defaults(layout => 'default', logged_in => 0, VERSION => time, body_class => 'default');

  # Normal route to controller
  my $r = $self->routes;
  $r->get('/')->to('client#route')->name('index');
  $r->post('/')->to('user#login_or_register');
  $r->any('/login')->to('user#login_or_register');
  $r->any('/register')->to('user#login_or_register', register_page => 1);
  $r->get('/logout')->to('user#logout')->name('logout');

  my $private_r = $r->bridge('/')->to('user#auth');
  my $settings_r = $private_r->route('/settings')->to(target => $config->{name});
  $settings_r->get('/')->to('user#settings')->name('settings');
  $settings_r->post('/add')->to('user#add_connection')->name('connection.add');
  $settings_r->get('/:cid', [cid => qr{\d+}])->to('user#settings')->name('connection.edit');
  $settings_r->post('/:cid', [cid => qr{\d+}])->to('user#edit_connection');

  $private_r->websocket('/socket')->to('chat#socket')->name('socket');

  $private_r->get('/conversations')->to('client#conversation_list', layout => undef)->name('conversation_list');
  $private_r->get('/notifications')->to('client#notification_list', layout => undef)->name('notification_list');
  $private_r->get('/command-history')->to('client#command_history');
  $private_r->post('/notifications/clear')->to('client#clear_notifications', layout => undef)->name('clear_notifications');
  $private_r->get('/:cid/*target', [cid => qr{\d+}])->to('client#view')->name('channel.view');
  $private_r->get('/:cid', [cid => qr{\d+}])->to('client#view')->name('server.view');

  $self->hook(
    before_dispatch => sub {
      my $c = shift;
      $c->stash(errors => {});    # this need to be set up each time, since it's a ref
    }
  );

  if($config->{backend}{embedded}) {
    Mojo::IOLoop->timer(0, sub {
      $self->core->start;
    });
  }

  # try to remind me to commit changes in compiled.css and .js as well
  $self->_compile_stylesheet;
  $self->_compile_javascript;
}

sub _compile_javascript { require Mojo::DOM;
  my $self = shift;
  my $config = $self->plugin('Config'); # make sure config file is loaded
  my $args = { template => 'empty', layout => 'default', title => '', VERSION => 0 };
  my $compiled = $self->home->rel_file('public/compiled.js');
  my $modified = +(stat $compiled)[9] || 0;
  my $mode = $self->mode;
  my $js = '';
  my($output, $format);

  $self->mode('compiling');
  ($output, $format) = $self->renderer->render(Mojolicious::Controller->new(app => $self), $args);
  $self->mode($mode);
  $output = Mojo::DOM->new($output);

  $output->find('script')->each(sub {
    my $file = $self->home->rel_file("public" . $_[0]->{src});
    $file = $self->_minify_javascript($file, $modified);
    $self->log->debug("Compiling $file");
    open my $JS, '<', $file or die "Read $file: $!";
    while(<$JS>) {
      m!^\s*//! and next;
      m!^\s*(.+)! or next;
      $js .= "$1\n";
    }
  });

  open my $COMPILED, '>', $compiled or die "Write $compiled: $!";
  print $COMPILED $js;
}

sub _compile_stylesheet {
  my $self = shift;
  my $less_file = $self->home->rel_file('public/less/main.less');
  my $css_file = $self->home->rel_file('public/compiled.css');

  system $ENV{LESSC_BIN} => -x => $less_file => $css_file if $ENV{LESSC_BIN};
  system $ENV{YUI_COMPRESSOR_BIN} => $css_file => -o => $css_file if $ENV{YUI_COMPRESSOR_BIN};
}

sub _minify_javascript {
  my($self, $file, $compiled_modified) = @_;
  my $mini = $file =~ s!/js/!/minified/!r; # ! st2 hack
  my $modified = +(stat $file)[9] || -1;

  return $file if $mini eq $file;
  return $mini if $modified < $compiled_modified;
  system $ENV{YUI_COMPRESSOR_BIN} => $file => -o => $mini if $ENV{YUI_COMPRESSOR_BIN};
  return -e $mini ? $mini : $file;
}

=head1 COPYRIGHT

Nordaaker

=head1 AUTHOR

Jan Henning Thorsen - jhthorsen@cpan.org

Marcus Ramberg

=cut

1;
