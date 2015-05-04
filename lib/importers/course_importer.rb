require "#{Rails.root}/lib/wiki"
require "#{Rails.root}/lib/importers/user_importer"

#= Imports and updates courses from Wikipedia into the dashboard database
class CourseImporter
  ################
  # Entry points #
  ################
  def self.get_course_info(course_id)
    Wiki.get_course_info course_id
  end

  ##############
  # API Access #
  ##############
  def self.update_all_courses(initial=false, raw_ids={})
    raw_ids = Wiki.course_list if raw_ids.empty?
    listed_ids = raw_ids.values.flatten
    course_ids = listed_ids | Course.where(listed: true).pluck(:id).map(&:to_s)

    if initial
      _minimum = course_ids.map(&:to_i).min
      maximum = course_ids.map(&:to_i).max
      course_ids = (0..maximum).to_a.map(&:to_s)
    end

    # Break up course_ids into smaller groups that Wikipedia's API can handle.
    data = Utils.chunk_requests(course_ids) { |c| get_course_info c }
    import_courses(raw_ids, data)
  end

  ###########
  # Helpers #
  ###########
  def self.import_courses(raw_ids, data)
    courses = []
    participants = {}
    listed_ids = raw_ids.values.flatten

    # Encountered an API error; cancel course import for today
    if data.include? nil
      Rails.logger.warn 'Network error. Course import cancelled.'
      return
    end

    # Delist courses that have been deleted
    Course.where(listed: true).each do |c|
      c.delist unless listed_ids.include?(c.id)
    end

    # Update courses from new data
    data.each do |c|
      c['course']['listed'] = listed_ids.include?(c['course']['id'])
      course = Course.new(id: c['course']['id']).update(c, false)
      courses.push course
      participants[c['course']['id']] = c['participants']
    end
    Course.import courses, on_duplicate_key_update: [:start, :end, :listed]

    # Update cohort membership
    update_cohorts raw_ids

    import_users participants
    import_assignments participants
  end

  def self.update_cohorts(raw_ids)
    Course.transaction do
      raw_ids.each do |ch, ch_courses|
        ch_courses = [ch_courses] unless ch_courses.is_a?(Array)
        cohort = Cohort.find_or_create_by(slug: ch)
        ch_new = ch_courses - cohort.courses.map { |co| co.id.to_s }
        ch_old = cohort.courses.map { |co| co.id.to_s } - ch_courses
        ch_new.each do |co|
          course = Course.find_by_id(co)
          course.cohorts << cohort if course
        end
        ch_old.each do |co|
          course = Course.find_by_id(co)
          course.cohorts.delete(cohort) if course
        end
      end
    end
  end

  def self.import_users(participants)
    users = []
    participants.each do |_course_id, groups|
      groups.each_with_index do |(r, _p), i|
        users = UserImporter.add_users(groups[r], i, nil, false) | users
      end
    end
    User.import users
  end

  def self.import_assignments(participants)
    assignments = []
    ActiveRecord::Base.transaction do
      participants.each do |course_id, group|
        group_flat = group.map do |role, users|
          users = [users] unless users.instance_of? Array
          users.empty? ? nil : users.each { |u| u.merge! 'role' => role }
        end
        group_flat = group_flat.compact.flatten.sort_by { |user| user['id'] }
        group_flat = update_enrollment course_id, group_flat
        assignments += update_assignments course_id, group_flat
      end
    end
    Assignment.import assignments
  end

  def self.update_enrollment(course_id, group_flat)
    # Update enrollment (add/remove students)
    user_ids = group_flat.map { |user| user['id'] }
    course = Course.find_by(id: course_id)

    return if user_ids.empty?
    role_index = %w(student instructor online_volunteer
                    campus_volunteer wiki_ed_staff)
    # Set up structures for operating on
    existing_flat = course.courses_users.map do |cu|
      { 'id' => cu.user_id.to_s, 'role' => role_index[cu.role] }
    end
    new_flat = group_flat.map do |u|
      { 'id' => u['id'], 'role' => u['role'] }
    end
    # Unenroll users who have been removed
    unless course.users.empty?
      unenrolled = (existing_flat - new_flat).map { |u| u['id'] }
      course.users.delete(course.users.find(unenrolled))
    end
    # Enroll new users
    enrolled = (new_flat - existing_flat).map { |u| u['id'] }

    return group_flat unless enrolled.count > 0
    group_flat.each do |u|
      next() unless enrolled.include? u['id']
      role = role_index.index(u['role'])
      role = 4 if u['username'].include? '(Wiki Ed)'
      CoursesUsers.new(user_id: u['id'], course: course, role: role).save
    end
    group_flat
  end

  def self.update_assignments(course_id, group_flat)
    # Add assigned articles
    assignments = []
    group_flat.each do |user|
      next unless user.key? 'article'
      is_array = user['article'].is_a?(Array)
      user['article'] = [user['article']] unless is_array
      user['article'].each do |article|
        assignment = {
          'user_id' => user['id'],
          'course_id' => course_id,
          'article_title' => article['title'],
          'article_id' => nil
        }
        article = Article.find_by(title: article['title'])
        assignment['article_id'] = article.nil? ? nil : article.id
        assignments.push Assignment.new(assignment)
      end
    end
    assignments
  end
end
