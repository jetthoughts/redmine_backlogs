class RbStory < Issue
    unloadable

    acts_as_list

    def self.condition(project_id, sprint_id, extras=[])
      c = if sprint_id.nil?  
        ["
          (project_id = ? or projects.parent_id = ?)
          and tracker_id in (?)
          and fixed_version_id is NULL
          and is_closed = ?", project_id, project_id, RbStory.trackers, false]
      else
        ["
          (project_id = ? or projects.parent_id = ?)
          and tracker_id in (?)
          and fixed_version_id = ?",
          project_id, project_id, RbStory.trackers, sprint_id]
      end

      if extras.size > 0
        c[0] += ' ' + extras.shift
        c += extras
      end

      return c
    end

    # this forces NULLS-LAST ordering
    ORDER = 'case when issues.position is null then 1 else 0 end ASC, case when issues.position is NULL then issues.id else issues.position end ASC'

    def self.backlog(project_id, sprint_id, options={})
      stories = []


      RbStory.find(:all,
            :order => RbStory::ORDER,
            :conditions => RbStory.condition(project_id, sprint_id),
            :joins => [:status, :project],
            :limit => options[:limit]).each_with_index {|story, i|
        story.rank = i + 1
        stories << story
      }

      return stories
    end

    def self.product_backlog(project, limit=nil)
      return RbStory.backlog(project.id, nil, :limit => limit)
    end

    def self.sprint_backlog(sprint, options={})
      return RbStory.backlog(sprint.project.id, sprint.id, options)
    end

    def self.create_and_position(params)
      attribs = params.select{|k,v| k != 'prev_id' and k != 'id' and RbStory.column_names.include? k }
      attribs = Hash[*attribs.flatten]
      s = RbStory.new(attribs)
      s.move_after(params['prev_id']) if s.save!
      return s
    end

    def self.find_all_updated_since(since, project_id)
      find(:all,
           :conditions => ["project_id = ? AND updated_on > ? AND tracker_id in (?)", project_id, Time.parse(since), trackers],
           :order => "updated_on ASC")
    end

    def self.trackers(type = :array)
      # somewhere early in the initialization process during first-time migration this gets called when the table doesn't yet exist
      return [] unless ActiveRecord::Base.connection.tables.include?('settings')

      trackers = Setting.plugin_redmine_backlogs[:story_trackers]
      return [] if trackers.blank?

      return trackers.join(',') if type == :string

      return trackers.map { |tracker| Integer(tracker) }
    end

    def tasks
      return RbTask.tasks_for(self.id)
    end

    def move_after(prev_id)
      # remove so the potential 'prev' has a correct position
      remove_from_list

      begin
        prev = self.class.find(prev_id)
      rescue ActiveRecord::RecordNotFound
        prev = nil
      end

      # if it's the first story, move it to the 1st position
      if prev.blank?
        insert_at
        move_to_top

      # if its predecessor has no position (shouldn't happen), make it
      # the last story
      elsif !prev.in_list?
        insert_at
        move_to_bottom

      # there's a valid predecessor
      else
        insert_at(prev.position + 1)
      end
    end

    def set_points(p)
        self.init_journal(User.current)

        if p.blank? || p == '-'
            self.update_attribute(:story_points, nil)
            return
        end

        if p.downcase == 's'
            self.update_attribute(:story_points, 0)
            return
        end

        p = Integer(p)
        if p >= 0
            self.update_attribute(:story_points, p)
            return
        end
    end

    def points_display(notsized='-')
        # For reasons I have yet to uncover, activerecord will
        # sometimes return numbers as Fixnums that lack the nil?
        # method. Comparing to nil should be safe.
        return notsized if story_points == nil || story_points.blank?
        return 'S' if story_points == 0
        return story_points.to_s
    end

    def task_status
        closed = 0
        open = 0
        self.descendants.each {|task|
            if task.closed?
                closed += 1
            else
                open += 1
            end
        }
        return {:open => open, :closed => closed}
    end

    def update_and_position!(params)
      attribs = params.except('project_id').select{|k,v| k != 'id' and RbStory.column_names.include? k }
      attribs = Hash[*attribs.flatten]
      result = journalized_update_attributes attribs
      if result and params[:prev]
        move_after(params[:prev])
      end
      result
    end

  def rank=(r)
    @rank = r
  end

  def rank
    if self.position.blank?
      extras = ['and ((issues.position is NULL and issues.id <= ?) or not issues.position is NULL)', self.id]
    else
      extras = ['and not issues.position is NULL and issues.position <= ?', self.position]
    end

    @rank ||= Issue.count(:conditions => RbStory.condition(self.project.id, self.fixed_version_id, extras), :joins => :status)

    return @rank
  end

  def self.at_rank(project_id, sprint_id, rank)
    return RbStory.find(:first,
                      :order => RbStory::ORDER,
                      :conditions => RbStory.condition(project_id, sprint_id),
                      :joins => :status,
                      :limit => 1,
                      :offset => rank - 1)
  end

  def burndown
    return @burndown if @burndown
    @burndown = {}

    dates = fixed_version.becomes(RbSprint).days(:active).collect{|d| Time.local(d.year, d.mon, d.mday, 0, 0, 0) }
    dates[0] = :first
    dates << :last

    @burndown[:status] = dates.collect{|d| IssueStatus.find(Integer(historic(d, 'status_id'))) }
    @burndown[:points] = dates.collect{|d| historic(d, 'story_points')}.collect{|p| p.nil? ? nil : Integer(p) }

    @burndown[:points_accepted] = (0..dates.size - 1).collect{|i| @burndown[:status][i].backlog == :accepted ? @burndown[:points][i] : 0 }

    taskdata = tasks.collect{|t| t.burndown }
    @burndown[:hours] = (0..dates.size - 1).collect{|i| taskdata.collect{|t| t[:hours][i] }.compact.inject(0) {|total, h| total + h}}

    @burndown[:points_resolved] = (0..dates.size - 1).collect{|i| @burndown[:hours][i] == 0 ? @burndown[:points][i] : 0}

    return @burndown
  end

end
